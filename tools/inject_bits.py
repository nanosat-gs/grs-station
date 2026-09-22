#!/usr/bin/env python3
"""Publica um fluxo de bits conhecido no envelope do demodulador.

Isola o detector de syncword do resto do cano: se os raw packets nao saem, e
preciso saber se a culpa e do DSP ou do detector, e de fora os dois modos de
falha sao identicos (nenhum pacote).
"""
import argparse, sys, time, zmq

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="tcp://*:5555")
    ap.add_argument("--syncword", default="BA67547E")
    ap.add_argument("--payload-bytes", type=int, default=64)
    ap.add_argument("--repeat", type=int, default=5)
    ap.add_argument("--settle", type=float, default=2.0)
    a = ap.parse_args()

    sync_bits = [int(b) for byte in bytes.fromhex(a.syncword) for b in f"{byte:08b}"]
    payload = bytes(range(a.payload_bytes))
    payload_bits = [int(b) for byte in payload for b in f"{byte:08b}"]
    # Preambulo de 0x55, como um enlace real, e para desalinhar o syncword de
    # qualquer fronteira de byte do proprio envelope.
    pre = [0, 1] * 37

    ctx = zmq.Context(); s = ctx.socket(zmq.PUB); s.bind(a.bind)
    print(f"inject_bits: bind {a.bind}, {len(sync_bits)} bits de sync, "
          f"{len(payload_bits)} de payload", flush=True)
    time.sleep(a.settle)
    for _ in range(a.repeat):
        s.send(bytes(pre + sync_bits + payload_bits))
        time.sleep(0.2)
    print(f"inject_bits: {a.repeat} mensagens publicadas", flush=True)
    s.close(linger=1000); ctx.term()
    return 0

if __name__ == "__main__":
    sys.exit(main())
