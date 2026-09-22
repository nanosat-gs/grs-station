#!/usr/bin/env python3
"""Assina a saida de bits do demodulador e resume o que chega.

Ferramenta de diagnostico do cano: separa "o demodulador nao produz bits" de
"o detector nao acha o syncword", que de fora tem exatamente a mesma cara --
nenhum raw packet.
"""
import argparse, sys, zmq

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--connect", default="tcp://localhost:5555")
    ap.add_argument("--messages", type=int, default=3)
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--syncword", default="BA67547E")
    a = ap.parse_args()

    ctx = zmq.Context(); s = ctx.socket(zmq.SUB)
    s.connect(a.connect); s.setsockopt_string(zmq.SUBSCRIBE, "")
    s.setsockopt(zmq.RCVTIMEO, int(a.timeout * 1000))
    print(f"tap_bits: connect {a.connect}", flush=True)

    want = [int(b) for byte in bytes.fromhex(a.syncword) for b in f"{byte:08b}"]

    for n in range(a.messages):
        try:
            payload = s.recv()
        except zmq.Again:
            print(f"tap_bits: TIMEOUT depois de {n} mensagens", file=sys.stderr); return 1
        bits = list(payload)
        ones = sum(1 for b in bits if b)
        # Busca bit a bit, como o detector faz.
        found = -1
        for i in range(len(bits) - len(want) + 1):
            if bits[i:i+len(want)] == want:
                found = i; break
        print(f"  msg {n}: {len(bits)} bits, {ones} uns, valores={sorted(set(bits))}, "
              f"syncword em {found}", flush=True)
    return 0

if __name__ == "__main__":
    sys.exit(main())
