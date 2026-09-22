#!/usr/bin/env python3
"""Assina os raw packets do detector de syncword e imprime o que chega.

É a ponta consumidora do cano de recepção — o lugar exato onde a fatia de
decode vai se plugar. Serve para duas coisas: fechar o B4 (provar que o cano
entrega pacote, e não só que há sinal) e documentar o envelope do raw packet
com um consumidor de verdade em vez de só com prosa.

O envelope, em três frames:

    [0] tópico    "raw_packet"
    [1] cabeçalho JSON de uma linha
    [2] payload   bytes empacotados MSB-first, os bits depois do syncword

Uso:

    python tools/collect_packets.py --connect tcp://grs-syncword:5558 --expect 3
"""

from __future__ import annotations

import argparse
import json
import sys

import zmq

# Bytes que o inject_iq planta depois do syncword. Conferir contra eles é o
# que separa "chegou um pacote" de "chegou o pacote certo": um detector com
# erro de deslocamento de bit entrega pacotes com aparência perfeita e
# conteúdo deslocado.
EXPECTED_PREFIX = bytes(range(0, 16))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--connect", default="tcp://localhost:5558")
    parser.add_argument("--expect", type=int, default=1, help="quantos pacotes exigir")
    parser.add_argument("--timeout", type=float, default=30.0, help="segundos")
    parser.add_argument(
        "--check-payload",
        action="store_true",
        help="exige que o payload comece com os bytes que o inject_iq planta",
    )
    args = parser.parse_args(argv)

    context = zmq.Context()
    subscriber = context.socket(zmq.SUB)
    subscriber.connect(args.connect)
    subscriber.setsockopt_string(zmq.SUBSCRIBE, "")
    subscriber.setsockopt(zmq.RCVTIMEO, int(args.timeout * 1000))

    print(f"collect_packets: connect {args.connect}, esperando {args.expect}", flush=True)

    received = 0
    mismatches = 0

    while received < args.expect:
        try:
            frames = subscriber.recv_multipart()
        except zmq.Again:
            print(
                f"collect_packets: TIMEOUT com {received}/{args.expect} pacotes",
                file=sys.stderr,
                flush=True,
            )
            return 1

        if len(frames) != 3:
            print(
                f"collect_packets: esperava 3 frames, veio {len(frames)}",
                file=sys.stderr,
                flush=True,
            )
            return 1

        topic, header_raw, payload = frames
        header = json.loads(header_raw)
        received += 1

        prefix = payload[: len(EXPECTED_PREFIX)]
        ok = prefix == EXPECTED_PREFIX

        if args.check_payload and not ok:
            mismatches += 1

        print(
            f"  pacote {header['seq']}: topico={topic.decode()} "
            f"bytes={len(payload)} bit_offset={header['bit_offset']} "
            f"max_sync_errors={header['max_sync_errors']} "
            f"payload[:8]={payload[:8].hex()} "
            f"{'ok' if ok else 'DIVERGE'}",
            flush=True,
        )

    subscriber.close()
    context.term()

    if args.check_payload and mismatches:
        print(
            f"collect_packets: {mismatches}/{received} pacotes com payload divergente",
            file=sys.stderr,
            flush=True,
        )
        return 1

    print(f"collect_packets: {received} pacotes recebidos", flush=True)

    return 0


if __name__ == "__main__":
    sys.exit(main())
