#!/usr/bin/env python3
"""Roda o cano de recepção inteiro e exporta o que acontece em cada estágio.

Não é simulação: o IQ sai daqui, atravessa o `grs-demodulator` e o
`grs-syncword-detector` DE VERDADE, nos containers, e o que volta é o que eles
produziram. O JSON resultante alimenta o relatório visual.

Três assinantes rodam em paralelo enquanto o IQ é publicado, porque ZMQ PUB
não guarda nada: quem não estiver escutando na hora perde.

    IQ (aqui)  ──:5556──▶ grs-demodulator ──:5555──▶ grs-syncword ──:5558──▶
         │                      │                          │
      amostras                bits                    raw packets
         └──────────────── report.json ────────────────────┘
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
import threading
import time

import numpy as np
import zmq

from grs_demodulator.gmsk import GMSK

SYNCWORD_HEX = "BA67547E"
PREAMBLE_BYTES = 32
PAYLOAD = list(range(0, 64))


def bits_of(data: bytes) -> list[int]:
    return [int(b) for byte in data for b in f"{byte:08b}"]


def find_bits(haystack: list[int], needle: list[int]) -> int:
    """Busca bit a bit, como o detector faz — sem assumir fronteira de byte."""
    for i in range(len(haystack) - len(needle) + 1):
        if haystack[i : i + len(needle)] == needle:
            return i
    return -1


def power_spectral_density(samples: np.ndarray, sample_rate: int, fft_size: int = 1024):
    """PSD média por Welch simplificado, em dB, com DC no centro."""
    window = np.hanning(fft_size)
    segments = len(samples) // fft_size
    if segments == 0:
        return [], []

    accumulator = np.zeros(fft_size)
    for index in range(segments):
        chunk = samples[index * fft_size : (index + 1) * fft_size] * window
        accumulator += np.abs(np.fft.fftshift(np.fft.fft(chunk))) ** 2

    psd = accumulator / segments
    psd_db = 10.0 * np.log10(psd + 1e-20)
    psd_db -= psd_db.max()  # Normaliza pelo pico: o eixo vira dBc.

    freqs = np.fft.fftshift(np.fft.fftfreq(fft_size, 1.0 / sample_rate))

    return freqs.tolist(), psd_db.tolist()


class Collector(threading.Thread):
    """Assinante em thread: junta mensagens até o tempo acabar."""

    def __init__(self, context, address: str, multipart: bool, deadline: float):
        super().__init__(daemon=True)
        self.address = address
        self.multipart = multipart
        self.deadline = deadline
        self.messages: list = []
        self._socket = context.socket(zmq.SUB)
        self._socket.connect(address)
        self._socket.setsockopt_string(zmq.SUBSCRIBE, "")
        self._socket.setsockopt(zmq.RCVTIMEO, 500)

    def run(self) -> None:
        while time.time() < self.deadline:
            try:
                self.messages.append(
                    self._socket.recv_multipart() if self.multipart else self._socket.recv()
                )
            except zmq.Again:
                continue
        self._socket.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="tcp://*:5556")
    parser.add_argument("--bits-from", default="tcp://r-demod:5555")
    parser.add_argument("--packets-from", default="tcp://r-sync:5558")
    parser.add_argument("--sample-rate", type=int, default=240000)
    parser.add_argument("--baud", type=int, default=4800)
    parser.add_argument("--bt", type=float, default=0.5)
    parser.add_argument("--repeat", type=int, default=30)
    parser.add_argument("--out", default="/out/report.json")
    args = parser.parse_args(argv)

    sps = args.sample_rate // args.baud
    syncword_bits = bits_of(bytes.fromhex(SYNCWORD_HEX))
    frame_bytes = [0x55] * PREAMBLE_BYTES + list(bytes.fromhex(SYNCWORD_HEX)) + PAYLOAD

    print(f"pipeline_report: modulando {len(frame_bytes)} bytes a {args.baud} baud", flush=True)
    baseband, _, _ = GMSK(args.bt, args.baud).modulate(frame_bytes, L=sps)
    baseband = baseband.astype(np.complex64)

    context = zmq.Context()
    publisher = context.socket(zmq.PUB)
    publisher.bind(args.bind)

    # Janela de coleta generosa: o injetor leva ~len(baseband)/fs por repetição,
    # e os assinantes precisam sobreviver ao último bloco.
    duration = args.repeat * (len(baseband) / args.sample_rate) + 12.0
    deadline = time.time() + duration

    bits_collector = Collector(context, args.bits_from, multipart=False, deadline=deadline)
    packets_collector = Collector(context, args.packets_from, multipart=True, deadline=deadline)
    bits_collector.start()
    packets_collector.start()

    time.sleep(3.0)  # Slow joiner: PUB descarta o que publica antes da conexão fechar.

    print(f"pipeline_report: publicando {args.repeat} frames", flush=True)
    for _ in range(args.repeat):
        for start in range(0, len(baseband), 8192):
            publisher.send(baseband[start : start + 8192].tobytes())
        time.sleep(len(baseband) / args.sample_rate)

    bits_collector.join()
    packets_collector.join()
    publisher.close(linger=1000)

    # --- estágio 1: o IQ que entrou ---
    preview_len = min(1200, len(baseband))
    preview_start = PREAMBLE_BYTES * 8 * sps - 200   # logo antes do syncword
    preview_start = max(0, min(preview_start, len(baseband) - preview_len))
    preview = baseband[preview_start : preview_start + preview_len]

    freqs, psd_db = power_spectral_density(baseband, args.sample_rate)

    # --- estágio 2: os bits que o demodulador produziu ---
    bit_windows = []
    for payload in bits_collector.messages[:6]:
        bits = list(payload)
        bit_windows.append(
            {
                "length": len(bits),
                "syncword_at": find_bits(bits, syncword_bits),
                "ones": sum(bits),
                # Fatia para desenhar: o suficiente para ver o preâmbulo, o
                # syncword e o começo do payload.
                "sample": bits[:900],
            }
        )

    # --- estágio 3: os raw packets ---
    expected = bytes(PAYLOAD)
    packets = []
    for frames in packets_collector.messages:
        if len(frames) != 3:
            continue
        header = json.loads(frames[1])
        payload = frames[2]
        wrong = [i for i in range(min(len(payload), len(expected))) if payload[i] != expected[i]]
        packets.append(
            {
                "seq": header["seq"],
                "bit_offset": header["bit_offset"],
                "bytes": len(payload),
                "max_sync_errors": header["max_sync_errors"],
                "detected_at": header["detected_at"],
                "payload_hex": payload[:32].hex(),
                "expected_hex": expected[:32].hex(),
                "bad_bytes": wrong[:16],
                "bad_count": len(wrong),
                "ok": not wrong,
            }
        )

    offsets = [p["bit_offset"] for p in packets]
    spacing = [b - a for a, b in zip(offsets, offsets[1:])]

    report = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "config": {
            "sample_rate_hz": args.sample_rate,
            "baud": args.baud,
            "bt": args.bt,
            "samples_per_symbol": sps,
            "syncword": SYNCWORD_HEX,
            "preamble_bytes": PREAMBLE_BYTES,
            "payload_bytes": len(PAYLOAD),
            "frame_bits": len(frame_bytes) * 8,
            "frames_sent": args.repeat,
            "modulated_samples": int(len(baseband)),
        },
        "iq": {
            "start_sample": int(preview_start),
            "i": [round(float(v), 5) for v in preview.real],
            "q": [round(float(v), 5) for v in preview.imag],
        },
        "psd": {
            "freq_hz": [round(f, 1) for f in freqs],
            "db": [round(v, 2) for v in psd_db],
        },
        "bits": {
            "syncword_bits": syncword_bits,
            "messages_seen": len(bits_collector.messages),
            "windows": bit_windows,
        },
        "packets": packets,
        "summary": {
            "packets": len(packets),
            "exact": sum(1 for p in packets if p["ok"]),
            "corrupted": sum(1 for p in packets if not p["ok"]),
            "bit_offset_spacing": spacing,
            "expected_spacing": len(frame_bytes) * 8,
        },
    }

    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report), encoding="utf-8")

    print(
        f"pipeline_report: {len(packets)} pacotes "
        f"({report['summary']['exact']} exatos, {report['summary']['corrupted']} corrompidos), "
        f"{len(bits_collector.messages)} janelas de bits -> {out}",
        flush=True,
    )

    return 0


if __name__ == "__main__":
    sys.exit(main())
