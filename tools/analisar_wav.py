#!/usr/bin/env python3
"""Analisa um WAV do gqrx com o DSP da estação, e mostra o que achou.

Existe para você conferir o cano com os SEUS arquivos, em vez de com as
fixtures que já vieram no repositório. Aponte para qualquer gravação de áudio
do gqrx em Narrow FM e veja quantos pacotes a estação encontra.

    python tools/analisar_wav.py caminho/do/beacon.wav
    python tools/analisar_wav.py downlink.wav --baud 2400

O WAV do gqrx NÃO é IQ: é a saída do discriminador de frequência, porque o
Narrow FM já fez essa etapa. Por isso a análise começa na recuperação de
tempo — exatamente onde o decodificador oficial do SpaceLab começa:

    digital.clock_recovery_mm_ff(samp_rate/baudrate, ...)

## Como julgar a saída

O número que importa é `size-tag a distância 0`. Achar um padrão de 32 bits
num fluxo é fácil e pode ser coincidência; achar um padrão de 32 bits SEGUIDO
de um codeword de tamanho válido do NGHam, sem um único bit errado, não é.

Se aparecerem syncwords mas nenhum size-tag exato, o sinal está sendo achado e
os bits depois dele estão errados — o suspeito é a recuperação de tempo, ou o
baud estar trocado.
"""

from __future__ import annotations

import argparse
import pathlib
import sys
import wave

import numpy as np

from grs_demodulator.timing_sync.mm import MM

# Da implementação de referência do NGHam (ngham.c, no spacelab-ufsc/grs).
NGHAM_SYNC = bytes((0x5D, 0xE6, 0x2A, 0x7E))
NGHAM_PREAMBLE = 0xAA

# O valor invertido que circulou na documentação. Fica aqui para a saída
# mostrar, lado a lado, que ele não acha nada num sinal real.
REVERSED_SYNC = bytes((0xBA, 0x67, 0x54, 0x7E))

NGHAM_SIZE_TAGS = (
    0b001110110100100111001101,
    0b010011011101101001010111,
    0b011101101001001110011010,
    0b100110111011010010101110,
    0b101000001111110101100011,
    0b110101100110111011111001,
    0b111011010010011100110100,
)


def expand(data: bytes, lsb_first: bool = False) -> list[int]:
    order = range(8) if lsb_first else range(7, -1, -1)

    return [(byte >> i) & 1 for byte in data for i in order]


def find_all(haystack: list[int], needle: list[int]) -> list[int]:
    """Busca bit a bit — o que sai do slicer não tem sincronismo de byte."""
    found: list[int] = []
    index = 0
    limit = len(haystack) - len(needle)

    while index <= limit:
        if haystack[index : index + len(needle)] == needle:
            found.append(index)
            index += len(needle)
        else:
            index += 1

    return found


def load(path: pathlib.Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as handle:
        rate = handle.getframerate()
        channels = handle.getnchannels()
        width = handle.getsampwidth()
        raw = handle.readframes(handle.getnframes())

    if width != 2:
        raise SystemExit(f"esperava 16 bits por amostra, veio {width * 8}")

    audio = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0

    if channels > 1:
        # Estéreo vira mono pela média. O gqrx grava mono, mas uma gravação
        # vinda de outro lugar pode não ser — e demodular só um canal daria
        # metade da energia sem dizer por quê.
        audio = audio.reshape(-1, channels).mean(axis=1)

    return audio, rate


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("wav", type=pathlib.Path)
    parser.add_argument("--baud", type=int, default=1200,
                        help="1200 para o beacon do FS-1, 2400 para o downlink")
    parser.add_argument("--max-seconds", type=float, default=0.0,
                        help="Analisa só os primeiros N segundos. 0 = o arquivo inteiro, "
                             "que é o padrão porque truncar é a causa nº 1 de 'não achei "
                             "nada': uma observação do SatNOGS dura 13 minutos e o "
                             "satélite só transmite em parte dela.")
    args = parser.parse_args(argv)

    if not args.wav.exists():
        raise SystemExit(f"não encontrei {args.wav}")

    audio, rate = load(args.wav)
    truncado = False
    if args.max_seconds > 0:
        limit = int(args.max_seconds * rate)
        if len(audio) > limit:
            audio = audio[:limit]
            truncado = True

    sps = rate / args.baud
    print(f"arquivo ........... {args.wav.name}")
    print(f"taxa .............. {rate} Hz")
    print(f"duração ........... {len(audio) / rate:.1f} s")
    print(f"baud .............. {args.baud}  ({sps:.1f} amostras por símbolo)")
    print(f"pico do áudio ..... {np.max(np.abs(audio)):.3f}")

    if sps < 4:
        print(f"\nAVISO: {sps:.1f} amostras por símbolo é pouco. Confira o --baud.")

    if len(audio) / rate > 120:
        print(f"\n(analisando {len(audio) / rate:.0f} s — pode levar alguns minutos)",
              flush=True)

    mm = MM(samp_rate=rate, baud=args.baud)
    bits: list[int] = []
    chunk = rate * 2

    for start in range(0, len(audio), chunk):
        bits.extend(int(b) for b in mm.decode_stream(audio[start : start + chunk]))

    esperado = int(len(audio) / rate * args.baud)
    ones = sum(bits) / len(bits) if bits else 0.0
    print(f"bits recuperados .. {len(bits)}  (esperado ~{esperado})")
    print(f"proporção de uns .. {ones * 100:.1f}%"
          f"{'   <- travado, a recuperação de tempo perdeu o sinal' if not 0.3 < ones < 0.7 else ''}")

    hits = find_all(bits, expand(NGHAM_SYNC))
    invertido = find_all(bits, expand(REVERSED_SYNC))

    print()
    print(f"syncword 5D E6 2A 7E (NGHam, MSB) .. {len(hits)}")
    print(f"syncword BA 67 54 7E (invertido) ... {len(invertido)}"
          "   <- deve ser 0 num sinal real")

    if not hits:
        print("\nNenhum syncword. Possíveis causas, na ordem em que eu olharia:")
        if truncado:
            print(f"  - VOCÊ TRUNCOU em {args.max_seconds:.0f} s. Rode sem --max-seconds:")
            print("    numa observação longa o satélite transmite só em parte dela,")
            print("    e o começo costuma ser só ruído. Foi o que me enganou primeiro.")
        print("  - o --baud está errado (1200 beacon, 2400 downlink do FS-1)")
        print("  - o gqrx não estava em Narrow FM")
        print("  - a passagem foi fraca demais e não há pacote legível")
        return 2

    exatos = 0
    print("\n  bit      t(s)    size-tag   frame")
    for offset in hits:
        segment = bits[offset + 32 : offset + 56]
        if len(segment) < 24:
            continue
        value = int("".join(map(str, segment)), 2)
        distancia = min(bin(value ^ tag).count("1") for tag in NGHAM_SIZE_TAGS)
        exato = distancia == 0
        exatos += exato
        print(f"  {offset:7d}  {offset / args.baud:6.2f}   0x{value:06X}   "
              f"{'NGHam' if exato else f'outro (dist {distancia})'}")

    antes = bits[max(0, hits[0] - 16) : hits[0]]
    alterna = all(a != b for a, b in zip(antes, antes[1:])) if len(antes) > 1 else False

    print()
    print(f"frames NGHam (size-tag exato) ...... {exatos}/{len(hits)}")
    print(f"preâmbulo antes do 1º sync ........ {''.join(map(str, antes))}"
          f"{'  (0xAA, como o ngham.c define)' if alterna else '  <- não alterna'}")

    if exatos:
        print(f"\nO cano encontrou {exatos} frame(s) NGHam com size-tag a distância ZERO.")
        print("Os demais são provavelmente beacons AX.25, que o FloripaSat-1")
        print("transmitia alternando com os NGHam.")
        return 0

    print("\nSyncwords achados, mas nenhum size-tag exato: os bits DEPOIS do")
    print("sync estão errados. Suspeitos: baud trocado, ou recuperação de tempo.")

    return 1


if __name__ == "__main__":
    sys.exit(main())
