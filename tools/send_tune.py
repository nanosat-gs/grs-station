#!/usr/bin/env python3
"""Publica mensagens `tune`, no lugar do grs-frequency-synthesizer.

Serve para exercitar a malha de sintonia antes de o sintetizador estar
adotado, e para provocar à mão os casos que uma passagem real demoraria a
produzir: sintonizar longe, voltar, varrer.

Contrato, o mesmo do sintetizador:

    [b"tune", b"<Hz em ASCII>"]
"""
import argparse, sys, time, zmq

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bind", default="tcp://*:5557")
    ap.add_argument("--settle", type=float, default=1.5,
                    help="espera antes do primeiro envio (PUB descarta sem assinante)")
    ap.add_argument("steps", nargs="+",
                    help="pares <segundos>:<Hz>, ex.: 0:145900000 10:146400000")
    a = ap.parse_args()

    ctx = zmq.Context(); s = ctx.socket(zmq.PUB); s.bind(a.bind)
    print(f"send_tune: bind {a.bind}", flush=True)
    time.sleep(a.settle)

    start = time.monotonic()
    for step in a.steps:
        when, _, hz = step.partition(":")
        if not hz:
            print(f"send_tune: passo inválido {step!r}, esperava <s>:<Hz>", file=sys.stderr)
            return 1
        delay = float(when) - (time.monotonic() - start)
        if delay > 0:
            time.sleep(delay)
        s.send_multipart([b"tune", str(int(float(hz))).encode()])
        print(f"send_tune: t={float(when):5.1f}s  tune -> {float(hz)/1e6:.4f} MHz", flush=True)

    s.close(linger=1000); ctx.term()
    return 0

if __name__ == "__main__":
    sys.exit(main())
