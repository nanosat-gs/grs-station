"""Do IQ à telemetria, sem Docker: simulador -> demodulador -> syncword -> decodificador.

    grs-sdr-sim (--frame general-telemetry)   um General Telemetry em quadro NGHam real
      -> VirtualSpectrum (ruído, atraso)      o que o rádio entregaria
      -> GRSDemodulator                       o DSP da estação, o mesmo do container
      -> busca de syncword (aqui, em Python)  a do service.c, com 1 bit de tolerância
      -> 258 bytes depois do syncword          o raw packet, como o detector publica
      -> telemetry_decoder.decode_packet       NGHam, cabeçalho, perfil, 0x10

O que este arquivo prova que nenhum dos repositórios prova sozinho: que o
quadro que o simulador monta (layout reescrito em fs2_frames.py, sem importar
o decoder) sobrevive à modulação, ao ruído e ao DSP, e sai do outro lado com
os mesmos valores, campo a campo.

Mesma divisão do test_rx_datapath_e2e.py: o detector C e o banco ficam fora
(são o teste com o compose de pé). O que fica dentro roda em qualquer máquina
com `bootstrap.ps1 -Dev`.
"""

from __future__ import annotations

import struct
from datetime import datetime, timezone

import numpy as np
import pytest

zmq = pytest.importorskip("zmq")  # noqa: F841  (o demodulador importa zmq no módulo)
pytest.importorskip("telemetry_decoder")

from grs_demodulator.grsdemodulator import GRSDemodulator  # noqa: E402
from sdr_sim import emitters as em  # noqa: E402
from sdr_sim import fs2_frames  # noqa: E402
from sdr_sim.spectrum import VirtualSpectrum  # noqa: E402
from telemetry_decoder.adapters.pyngham_link import PyNghamLinkDecoder  # noqa: E402
from telemetry_decoder.application.decode_packet import decode_packet  # noqa: E402
from telemetry_decoder.domain.models import FrameStatus, RawPacket  # noqa: E402
from telemetry_decoder.domain.packets.general_telemetry import FIELDS  # noqa: E402

SAMPLE_RATE = 240_000
BAUD = 4800                 # o 0x10 desce pelo UHF de dados
CENTER = 468_400_000.0
BLOCK_SAMPLES = 24_000
SECONDS = 4.0
TIMESTAMP = 1_791_201_600   # 2026-10-05 12:00:00 UTC
# A fatia que a estação publica: 3 de size tag + o maior codeword (255).
SLICE_BYTES = 258


def bits_of(data: bytes) -> np.ndarray:
    return np.unpackbits(np.frombuffer(data, dtype=np.uint8))


def raw_packets(bits: np.ndarray, max_errors: int = 1) -> list[bytes]:
    """Como o service.c: syncword a até `max_errors` bits, a fatia seguinte
    empacotada MSB primeiro, e o avanço só até o fim do syncword."""
    sync = bits_of(em.NGHAM_SYNCWORD)
    distance = np.count_nonzero(
        np.lib.stride_tricks.sliding_window_view(bits, len(sync)) != sync, axis=1)
    found, index = [], 0
    for position in np.flatnonzero(distance <= max_errors):
        if position < index:
            continue
        start = position + len(sync)
        chunk = bits[start:start + SLICE_BYTES * 8]
        if len(chunk) < SLICE_BYTES * 8:
            break
        found.append(np.packbits(chunk).tobytes())
        index = start
    return found


@pytest.fixture(scope="module")
def decoded():
    packet = fs2_frames.general_telemetry(TIMESTAMP)
    fs2 = em.fs2_beacon(CENTER, SAMPLE_RATE, BAUD, fs2_frames.ngham_frame(packet), gap_s=0.3)
    # 10 dB de SNR e um atraso de 13 amostras: o sincronismo de tempo tem de
    # trabalhar de verdade (ver o --offset do tools/bancada_demod.py).
    spectrum = VirtualSpectrum(CENTER, SAMPLE_RATE, [fs2], snr_db=10.0, seed=2026)
    demod = GRSDemodulator(env={"GRS_DEMOD_BAUD": str(BAUD)})

    buffer = bytearray(np.zeros(13, dtype=np.complex64).tobytes())
    bits: list[int] = []
    for _ in range(int(SECONDS * SAMPLE_RATE / BLOCK_SAMPLES)):
        buffer.extend(spectrum.block(BLOCK_SAMPLES).tobytes())
        if len(buffer) >= demod.window_bytes:
            bits.extend(demod._process_samples(bytes(buffer)))
            buffer.clear()

    link = PyNghamLinkDecoder()
    outcomes = [
        decode_packet(RawPacket(id=i, received_at=datetime.now(timezone.utc), radio="uhf",
                                payload=payload), link, "e2e")
        for i, payload in enumerate(raw_packets(np.array(bits, dtype=np.uint8)))
    ]
    return packet, outcomes


def test_as_rajadas_viram_general_telemetry(decoded):
    _, outcomes = decoded
    ok = [o for o in outcomes if o.frame.status is FrameStatus.OK]

    # ~0,63 s por ciclo (0,33 de quadro + 0,3 de silêncio) em 4 s: 6 rajadas
    # inteiras. O que não for OK tem de ter um motivo de enlace, nunca outro.
    assert len(ok) >= 5
    assert all(o.frame.status is FrameStatus.NGHAM_FAILED for o in outcomes if o not in ok)


def test_os_valores_atravessam_o_cano_campo_a_campo(decoded):
    packet, outcomes = decoded
    record = next(o.record for o in outcomes if o.frame.status is FrameStatus.OK)

    expected = {field.name: struct.unpack_from(">" + field.fmt, packet, field.offset)[0]
                for field in FIELDS}
    assert record.values == expected
    assert record.layout == "obdh2-111"
    assert record.sat_time == datetime(2026, 10, 5, 12, 0, tzinfo=timezone.utc)


def test_cabecalho_e_perfil(decoded):
    _, outcomes = decoded
    frame = next(o.frame for o in outcomes if o.frame.status is FrameStatus.OK)

    assert (frame.callsign, frame.sat_profile, frame.pkt_type) == ("PY0EFS", "fs2", "general_telemetry")
    assert frame.radio_mismatch is False
    assert frame.rs_errors >= 0
