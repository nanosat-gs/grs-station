#!/usr/bin/env python3
"""Bancada offline do demodulador: quantos pacotes sobrevivem, e por quê não.

    grs-sdr-sim (sinal) -> GRSDemodulator (o MESMO da estação) -> busca de
    syncword -> confere os 64 bytes contra o que foi transmitido

Sem ZMQ e sem Docker Compose: o sinal é gerado em processo e entregue ao
demodulador em janelas do mesmo tamanho que ele usa ao vivo. O resultado é
determinístico (semente fixa), então uma correção no DSP pode ser medida
antes e depois com o mesmo número de pacotes, e não no olho.

Uso (dentro da imagem do demodulador, que já tem numpy e scipy):

    docker run --rm -v "${PWD}/tools:/tools" -v "${PWD}/repos/grs-sdr-sim/src:/sim" \\
        -v "${PWD}/repos/grs-demodulator:/app" gs-stationmanager-grs-demodulator \\
        sh -c "PYTHONPATH=/sim:/app python /tools/bancada_demod.py --snr 20 --seconds 40"
"""

from __future__ import annotations

import argparse
import sys

import numpy as np

from grs_demodulator.grsdemodulator import GRSDemodulator
from sdr_sim import emitters as em
from sdr_sim.spectrum import VirtualSpectrum

SAMPLE_RATE = 240_000
BAUD = 4800
CENTER = 145_900_000.0
BLOCK_SAMPLES = 8192
SYNCWORD = bytes((0x5D, 0xE6, 0x2A, 0x7E))
PAYLOAD = bytes(range(64))


def bits_of(data: bytes) -> np.ndarray:
    return np.unpackbits(np.frombuffer(data, dtype=np.uint8))


def find_packets(bits: np.ndarray, max_errors: int = 1) -> list[tuple[int, bytes]]:
    """Syncword com até `max_errors` bits errados, como o detector; devolve
    (posição logo depois do syncword, 64 bytes)."""
    sync = bits_of(SYNCWORD)
    payload_bits = len(PAYLOAD) * 8
    if len(bits) < len(sync) + payload_bits:
        return []

    windows = np.lib.stride_tricks.sliding_window_view(bits, len(sync))
    distance = np.count_nonzero(windows != sync, axis=1)
    found = []
    index = 0
    candidates = np.flatnonzero(distance <= max_errors)

    for position in candidates:
        if position < index:
            continue
        start = position + len(sync)
        if start + payload_bits > len(bits):
            break
        found.append((start, np.packbits(bits[start : start + payload_bits]).tobytes()))
        index = start + payload_bits

    return found


def run(snr_db: float | None, seconds: float, seed: int, doppler_hz: float,
        env: dict[str, str] | None = None, offset: int = 0) -> dict:
    doppler = em.PassDoppler(doppler_hz, seconds) if doppler_hz else None
    fs2 = em.fs2_beacon(CENTER, SAMPLE_RATE, BAUD, PAYLOAD, gap_s=0.5, doppler=doppler)
    spectrum = VirtualSpectrum(CENTER, SAMPLE_RATE, [fs2], snr_db=snr_db, seed=seed)
    demod = GRSDemodulator(env=env or {})

    period = len(fs2.waveform)
    total = int(seconds * SAMPLE_RATE)
    # Atraso de `offset` amostras: os símbolos do simulador começam alinhados
    # na amostra 0, e um sinal real não. Sem variar isto, um sincronismo de
    # tempo que não rastreia nada passa na bancada por sorte de alinhamento —
    # foi exatamente o que escondeu o defeito do M&M.
    buffer = bytearray(np.zeros(offset, dtype=np.complex64).tobytes())
    bits: list[int] = []

    generated = 0
    while generated < total:
        buffer.extend(spectrum.block(BLOCK_SAMPLES).tobytes())
        generated += BLOCK_SAMPLES
        # Mesma regra do laço ao vivo: acumula até a janela e processa tudo.
        if len(buffer) >= demod.window_bytes:
            bits.extend(demod._process_samples(bytes(buffer)))
            buffer.clear()

    # Uma rajada conta como enviada se o QUADRO dela (não o silêncio depois)
    # terminou dentro do que o demodulador processou, com folga para o atraso
    # dos filtros.
    processed = generated - len(buffer) // 8
    burst = period - int(round(0.5 * SAMPLE_RATE))
    latency = 4 * SAMPLE_RATE // BAUD
    sent = sum(1 for k in range(processed // period + 1)
               if k * period + burst + latency <= processed)
    packets = find_packets(np.array(bits, dtype=np.uint8))
    ok = sum(1 for _, payload in packets if payload == PAYLOAD)

    starts = [start for start, _ in packets]
    return {
        # Número da rajada (0 = a primeira) de cada pacote que divergiu.
        "bad_bursts": [round(start * (SAMPLE_RATE / BAUD) / period)
                       for start, payload in packets if payload != PAYLOAD],
        "sent": sent,
        "found": len(packets),
        "ok": ok,
        "diverge": len(packets) - ok,
        "bits_per_period": period / (SAMPLE_RATE / BAUD),
        "spacing": sorted(set(np.diff(starts).tolist())) if len(starts) > 1 else [],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--snr", default="20", help="dB, ou 'none' para sinal limpo")
    parser.add_argument("--seconds", type=float, default=40.0)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--doppler", type=float, default=0.0, help="pico em Hz")
    parser.add_argument("--dc-tau", type=float, default=None,
                        help="GRS_DEMOD_DC_TAU_S, em segundos. Omitido = padrão do demodulador.")
    parser.add_argument("--offset", type=int, default=25,
                        help="Atraso em amostras (fase de símbolo). 25 = meio símbolo, o "
                             "pior caso a 50 amostras/símbolo.")
    args = parser.parse_args()

    snr = None if args.snr.lower() == "none" else float(args.snr)
    env = {} if args.dc_tau is None else {"GRS_DEMOD_DC_TAU_S": str(args.dc_tau)}
    r = run(snr, args.seconds, args.seed, args.doppler, env, args.offset)

    lost = r["sent"] - r["ok"]
    print(f"SNR {args.snr:>5} dB | enviados {r['sent']:3} | achados {r['found']:3} | "
          f"corretos {r['ok']:3} | divergentes {r['diverge']:3} | perdidos {lost:3} "
          f"({100 * r['ok'] / max(r['sent'], 1):5.1f}% íntegros)")
    print(f"           período {r['bits_per_period']:.2f} bits; espaçamentos vistos {r['spacing'][:8]}"
          f"; rajadas divergentes {r['bad_bursts'][:10]}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
