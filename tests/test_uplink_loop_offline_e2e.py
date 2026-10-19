"""A malha do uplink fechada, sem Docker: manda o TC, o satélite responde, a estação associa.

    grs-uplink (UplinkService)        TC -> SLP + HMAC -> NGHam -> GMSK, Doppler
      -> ZMQ REQ :5559 de verdade      o contrato de TX (o mesmo do USRP)
      -> grs-sdr-sim (TxServer)        o satélite simulado: demodula, confere o HMAC,
                                       responde como o process_tc.c v1.0
      -> resposta em quadro NGHam      0x02 pela VHF (1200 baud), 0x13 pela UHF (4800)
      -> VirtualSpectrum + GRSDemodulator + busca de syncword   o RX da estação
      -> telemetry_decoder.decode_packet                         0x02 / 0x13 decodificados
      -> tc_scheduler.tc_lifecycle                               casa e decide

O que só este arquivo prova: que os cinco repositórios concordam entre si —
o SLP que o uplink monta é o que o satélite simulado aceita, a rajada GMSK é
demodulável pelo receptor de bordo (escrito à parte), a resposta sobrevive ao
DSP de recepção da estação, e o casamento do Scheduler reconhece nela o TC
que subiu. O banco fica fora (é o teste com o compose de pé): aqui a
transmissão e o quadro viram os objetos que o store do Scheduler leria.
"""

from __future__ import annotations

import socket
import threading
from datetime import datetime, timedelta, timezone

import numpy as np
import pytest

zmq = pytest.importorskip("zmq")
pytest.importorskip("grs_uplink")
pytest.importorskip("telemetry_decoder")
pytest.importorskip("tc_scheduler")

from grs_demodulator.grsdemodulator import GRSDemodulator  # noqa: E402
from grs_uplink.adapters.ngham_framer import NghamFramer  # noqa: E402
from grs_uplink.adapters.zmq_radio import ZmqRadioTransmitter  # noqa: E402
from grs_uplink.application.transmit import UplinkService, UplinkSettings  # noqa: E402
from grs_uplink.domain.models import Telecommand, TxStatus  # noqa: E402
from sdr_sim import emitters as em  # noqa: E402
from sdr_sim.control import SimController  # noqa: E402
from sdr_sim.satellite import SatelliteModel  # noqa: E402
from sdr_sim.spectrum import VirtualSpectrum  # noqa: E402
from sdr_sim.uplink import TxServer, UplinkStation  # noqa: E402
from tc_scheduler.tc_lifecycle import ResponseFrame, Transmission, decide, match_rule  # noqa: E402
from telemetry_decoder.adapters.pyngham_link import PyNghamLinkDecoder  # noqa: E402
from telemetry_decoder.application.decode_packet import decode_packet  # noqa: E402
from telemetry_decoder.domain.models import FrameStatus, RawPacket  # noqa: E402

RATE = 240_000
VHF = 145_900_000.0
UHF = 468_400_000.0
BAUD = {"vhf": 1200, "uhf": 4800}
CARRIER = {"vhf": VHF, "uhf": UHF}
STATION = "PY0SIM"
KEYS = {"activate_module": b"TESTE-actv-mod01", "deactivate_module": b"TESTE-deac-mod01"}
SLICE_BYTES = 258
BLOCK = 24_000


# --- o lado da estação que transmite ---------------------------------------------------


class OneTelecommand:
    """O store do grs-uplink com um TC só, e as tentativas guardadas."""

    def __init__(self, command_type: str, parameters: dict) -> None:
        self.telecommand = Telecommand(1, 1, "FS2", command_type, parameters, "pending")
        self.finished = []

    def read_telecommand(self, telecommand_id):
        return self.telecommand

    def start_transmission(self, *args):
        return 1

    def finish_transmission(self, transmission_id, report):
        self.finished.append(report)


class NoDoppler:
    def current_hz(self):
        return None


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


# --- o lado da estação que recebe ---------------------------------------------------------


def raw_packets(bits: np.ndarray, max_errors: int = 1) -> list[bytes]:
    """A busca de syncword do service.c (a mesma do test_telemetry_offline_e2e)."""
    sync = np.unpackbits(np.frombuffer(em.NGHAM_SYNCWORD, dtype=np.uint8))
    distance = np.count_nonzero(np.lib.stride_tricks.sliding_window_view(bits, len(sync)) != sync, axis=1)
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


def receive(radio: str, frame: bytes, seconds: float = 2.0):
    """A resposta no ar, pelo RX da estação daquele rádio, até o decoder."""
    fs2 = em.fs2_beacon(CARRIER[radio], RATE, BAUD[radio], frame, gap_s=0.3)
    spectrum = VirtualSpectrum(CARRIER[radio], RATE, [fs2], snr_db=12.0, seed=7)
    demod = GRSDemodulator(env={"GRS_DEMOD_BAUD": str(BAUD[radio])})
    buffer = bytearray(np.zeros(17, dtype=np.complex64).tobytes())
    bits: list[int] = []
    for _ in range(int(seconds * RATE / BLOCK)):
        buffer.extend(spectrum.block(BLOCK).tobytes())
        if len(buffer) >= demod.window_bytes:
            bits.extend(demod._process_samples(bytes(buffer)))
            buffer.clear()
    now = datetime.now(timezone.utc)
    outcomes = [decode_packet(RawPacket(id=i, received_at=now, radio=radio, payload=p),
                              PyNghamLinkDecoder(), "e2e")
                for i, p in enumerate(raw_packets(np.array(bits, dtype=np.uint8)))]
    return next(o for o in outcomes if o.frame.status is FrameStatus.OK)


# --- a malha -------------------------------------------------------------------------------


@pytest.fixture
def loop():
    """O satélite simulado ouvindo numa :5559 real, e a função que manda um TC."""
    stop = threading.Event()
    fs2 = em.fs2_beacon(VHF, RATE, 1200, bytes(16))
    controller = SimController(VirtualSpectrum(VHF, RATE, [fs2], snr_db=None, seed=1), 4096)
    responses: list[tuple[str, bytes]] = []
    station = UplinkStation(SatelliteModel(KEYS), controller, VHF, 1200,
                            respond=lambda radio, frame: responses.append((radio, frame)),
                            shutdown=stop)
    address = f"tcp://127.0.0.1:{free_port()}"
    server = TxServer(address, station, stop)
    server.start()
    radio = ZmqRadioTransmitter(address, timeout_s=5)

    def send(command_type: str, parameters: dict, keys=KEYS, callsign=STATION):
        store = OneTelecommand(command_type, parameters)
        service = UplinkService(store, NghamFramer(), radio, NoDoppler(), keys,
                                UplinkSettings(callsign, VHF, 1200, RATE))
        reply = service.transmit(1)
        # A rajada já saiu (o ack só vem depois); o satélite processa logo em seguida.
        deadline = datetime.now() + timedelta(seconds=3)
        while station.bursts < send.count + 1 and datetime.now() < deadline:
            stop.wait(0.02)
        send.count += 1
        return reply, store, list(responses)

    send.count = 0
    yield send, station
    stop.set()
    radio.close()
    server.join(timeout=3)


def transmission_from(reply: dict, callsign: str = STATION) -> Transmission:
    """A linha de uplink_transmissions que o grs-uplink teria gravado."""
    return Transmission(transmission_id=reply["transmission_id"], telecommand_id=1, satellite_id=1,
                        tc_pkt_id=reply["tc_pkt_id"],
                        expected_response_pkt_id=reply["expected_response_pkt_id"],
                        station_callsign=callsign, ended_at=datetime.now(timezone.utc),
                        telecommand_status="sent")


def response_from(outcome) -> ResponseFrame:
    """A linha de decoded_frames (e de fs2_tc_feedback) que o decoder teria gravado."""
    values = outcome.record.values if outcome.record else {}
    return ResponseFrame(decoded_frame_id=1, raw_packet_id=outcome.frame.raw_packet_id,
                         received_at=outcome.frame.received_at, radio=outcome.frame.radio,
                         status=outcome.frame.status.value, pkt_id=outcome.frame.pkt_id,
                         payload=outcome.frame.ngham_payload, detail=outcome.frame.detail,
                         error_code=values.get("error_code"))


def test_ping_sobe_o_pong_desce_pela_vhf_e_confirma(loop):
    send, _ = loop

    reply, store, responses = send("PING", {})

    assert reply["status"] == "ack" and store.finished[0].status is TxStatus.ACK
    [(radio, frame)] = responses
    assert radio == "vhf"
    outcome = receive(radio, frame)
    assert outcome.table == "fs2_ping_answer"
    assert outcome.record.values == {"requester_callsign": STATION}

    response, transmission = response_from(outcome), transmission_from(reply)
    assert match_rule(response, transmission) == "callsign"
    assert decide(response).status == "confirmed"


def test_activate_module_com_hmac_desce_pela_uhf_e_confirma(loop):
    send, _ = loop

    reply, _, responses = send("ACTIVATE_MODULE", {"module_id": 3})

    [(radio, frame)] = responses
    assert radio == "uhf"
    outcome = receive(radio, frame)
    assert outcome.table == "fs2_tc_feedback"
    assert outcome.record.values["tc_id"] == 0x45
    assert outcome.record.values["error_code"] == 0

    response = response_from(outcome)
    assert match_rule(response, transmission_from(reply)) == "callsign+tc_id"
    assert decide(response).status == "confirmed"


def test_erro_do_satelite_vira_failed_com_o_motivo(loop):
    send, station = loop
    station.satellite.fail_next(-2)

    reply, _, responses = send("DEACTIVATE_MODULE", {"module_id": 1})

    decision = decide(response_from(receive(*responses[-1])))
    assert decision.status == "failed"
    assert "falha de comunicação com o subsistema" in decision.message


def test_chave_errada_o_satelite_fica_calado(loop):
    send, station = loop
    wrong = {"activate_module": b"chave-errada-123"}

    reply, _, responses = send("ACTIVATE_MODULE", {"module_id": 3}, keys=wrong)

    assert reply["status"] == "ack"            # a estação transmitiu
    assert responses == []                     # e o satélite rejeitou em silêncio
    assert station.satellite.rejected == 1


def test_resposta_ao_ping_de_outra_estacao_nao_casa_com_o_nosso(loop):
    send, _ = loop

    _, _, responses = send("PING", {}, callsign="PP5ABC")
    ours = transmission_from({"transmission_id": 2, "tc_pkt_id": 0x40,
                              "expected_response_pkt_id": 0x02})

    assert match_rule(response_from(receive(*responses[-1])), ours) is None
