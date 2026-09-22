#!/usr/bin/env python3
"""Publica IQ sintético no envelope do `grs-iq-rx`, para exercitar o cano de
recepção sem rádio.

Existe porque o caminho de dados RX não pode depender de uma passagem de LEO
para ser testado: uma passagem dura dez minutos, não se repete quando se quer,
e não é determinística. Este injetor ocupa o lugar do SDR e publica um sinal
cujo conteúdo é conhecido de antemão, então dá para afirmar se o que saiu do
outro lado está certo.

É também a semente do gerador de fixtures do E2: o mesmo sinal que ele publica
ao vivo pode ser gravado numa captura SigMF pelo `grs-iq-recorder`.

O que ele reproduz do `grs-iq-rx`:

  - BIND de um PUB (não connect) — quem consome é que conecta;
  - uma mensagem por bloco, SEM frame de tópico;
  - payload em complex64 little-endian intercalado (`cf32_le`).

O DSP é o do próprio `grs-demodulator` (a classe GMSK): modular com o mesmo
código que demodula evita que o teste passe por acidente, provando apenas que
dois bugs simétricos se cancelam — e, principalmente, evita escrever um
modulador nosso só para testar o deles.

Uso (dentro da rede do compose, com a imagem do demodulador):

    python tools/inject_iq.py --bind tcp://*:5556 --repeat 20
"""

from __future__ import annotations

import argparse
import sys
import time

import numpy as np
import zmq

from grs_demodulator.gmsk import GMSK

# Syncword do NGHam usado pelo enlace do FloripaSat.
SYNCWORD = [0xBA, 0x67, 0x54, 0x7E]

# Preâmbulo de 0x55 = 01010101: transição a cada bit, que é o que o
# sincronismo de tempo precisa para travar antes de o syncword chegar. Sem
# preâmbulo o Mueller & Muller ainda está convergindo quando o syncword passa,
# e o detector não acha nada.
PREAMBLE_BYTES = 32

# Payload conhecido depois do syncword. Não é um frame NGHam válido — montar
# um é trabalho da fatia de decode. O que se afirma aqui é que o cano entrega
# bytes delimitados por syncword, não que eles decodificam.
PAYLOAD = list(range(0, 64))


def build_frame() -> list[int]:
    """Preâmbulo + syncword + payload, como lista de bytes."""
    return [0x55] * PREAMBLE_BYTES + SYNCWORD + PAYLOAD


def modulate(frame: list[int], sample_rate_hz: int, baud: int, bt: float) -> np.ndarray:
    """Modula o frame e devolve a banda-base complexa em complex64.

    O fator de sobreamostragem É as amostras por símbolo: é isso que faz o
    sinal sair exatamente na taxa que o demodulador espera. Um descasamento
    aqui não dá erro — dá bits errados.
    """
    samples_per_symbol = sample_rate_hz // baud

    if sample_rate_hz % baud != 0:
        raise SystemExit(
            f"taxa {sample_rate_hz} não é múltipla de {baud} baud; "
            "o resto viraria erro de fase acumulado"
        )

    baseband, _, _ = GMSK(bt, baud).modulate(frame, L=samples_per_symbol)

    return baseband.astype(np.complex64)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="tcp://*:5556")
    parser.add_argument("--sample-rate", type=int, default=240000)
    parser.add_argument("--baud", type=int, default=4800)
    parser.add_argument("--bt", type=float, default=0.5)
    parser.add_argument(
        "--repeat", type=int, default=10, help="quantas vezes repetir o frame"
    )
    parser.add_argument(
        "--block-samples",
        type=int,
        default=8192,
        help="amostras por mensagem ZMQ, como o bloco do grs-iq-rx",
    )
    parser.add_argument(
        "--settle",
        type=float,
        default=1.0,
        help="segundos de espera antes de publicar, para os assinantes conectarem",
    )
    args = parser.parse_args(argv)

    baseband = modulate(build_frame(), args.sample_rate, args.baud, args.bt)

    context = zmq.Context()
    publisher = context.socket(zmq.PUB)
    publisher.bind(args.bind)

    print(f"inject_iq: bind {args.bind}", flush=True)
    print(
        f"inject_iq: {args.sample_rate} S/s, {args.baud} baud, "
        f"{args.sample_rate // args.baud} amostras/símbolo",
        flush=True,
    )
    print(f"inject_iq: frame de {len(baseband)} amostras, {args.repeat}x", flush=True)

    # ZMQ PUB descarta o que publica antes de o assinante concluir a conexão —
    # o problema clássico do "slow joiner". Sem esta espera, as primeiras
    # mensagens somem e o teste falha por motivo que não tem nada a ver com
    # DSP.
    time.sleep(args.settle)

    total_samples = 0

    for _ in range(args.repeat):
        for start in range(0, len(baseband), args.block_samples):
            block = baseband[start : start + args.block_samples]

            # Uma mensagem por bloco, sem frame de tópico — o demodulador faz
            # recv() simples, e um tópico na frente viraria a mensagem dele.
            publisher.send(block.tobytes())
            total_samples += len(block)

        # Sem pausa nenhuma o assinante não consegue drenar e o ZMQ começa a
        # descartar; esta é a vazão real do SDR, aproximada.
        time.sleep(len(baseband) / args.sample_rate)

    print(f"inject_iq: {total_samples} amostras publicadas", flush=True)

    # LINGER para o último bloco sair antes de o processo morrer.
    publisher.close(linger=1000)
    context.term()

    return 0


if __name__ == "__main__":
    sys.exit(main())
