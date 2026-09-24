"""O caminho de recepção contra sinal REAL do FloripaSat-1.

    WAV (gqrx, Narrow FM) -> MM -> bits -> syncword NGHam -> size tag

A fixture é um recorte de 8 s de um beacon gravado do ar em 2019-12-20 pelo
radioamador DK3WN. Ver `tests/fixtures/README.md` para a procedência.

## O que este arquivo prova que o teste sintético não pode

`test_rx_datapath_e2e.py` exercita mais etapas — ele parte de IQ e atravessa o
discriminador, o filtro casado e a gravação. Mas o sinal dele sai do nosso
próprio simulador, e as CONSTANTES dos dois vêm do mesmo repositório. Se um
valor estiver errado nos dois, eles concordam e o teste fica verde.

Foi o que aconteceu: o simulador emitia `BA 67 54 7E` e o detector procurava
`BA 67 54 7E`. Contra o satélite de verdade, aquilo acha ZERO pacotes.

Este arquivo existe para que isso não volte. Ele não testa o nosso DSP contra
o nosso sinal — testa contra o que um satélite realmente transmitiu.

## Por que ele começa na recuperação de tempo

O WAV não é IQ: é a saída do discriminador de frequência, porque o gqrx em
Narrow FM já fez essa etapa. É exatamente onde o decodificador oficial do
SpaceLab começa:

    digital.clock_recovery_mm_ff(samp_rate/baudrate, ...)   # 48000/1200 = 40
"""

from __future__ import annotations

import pathlib
import wave

import numpy as np
import pytest

from grs_demodulator.timing_sync.mm import MM

FIXTURE = pathlib.Path(__file__).parent / "fixtures" / "floripasat1-beacon-1200.wav"

SAMPLE_RATE = 48_000
BAUD = 1200  # beacon do FS-1; o downlink é 2400

# Da implementação de referência do NGHam (ngham.c):
#     const uint8_t NGH_SYNC[]   = {0x5D, 0xE6, 0x2A, 0x7E};
#     const uint8_t NGH_PREAMBLE = 0xAA;
NGHAM_SYNC = bytes((0x5D, 0xE6, 0x2A, 0x7E))

# O valor que o documento da fatia carregava: o MESMO vetor com os bits de
# cada byte invertidos. Fica aqui como guarda de regressão — ver o teste que
# exige que ele ache zero.
REVERSED_SYNC = bytes((0xBA, 0x67, 0x54, 0x7E))

# Os sete codewords de tamanho do NGHam, de ngham.c. São os 24 bits logo
# depois do syncword, e casar um deles a distância ZERO é o que separa "achei
# um padrão de 32 bits" de "achei um frame".
NGHAM_SIZE_TAGS = (
    0b001110110100100111001101,
    0b010011011101101001010111,
    0b011101101001001110011010,
    0b100110111011010010101110,
    0b101000001111110101100011,
    0b110101100110111011111001,
    0b111011010010011100110100,
)

# Medido nesta fixture. Congelado de propósito: se qualquer um destes números
# mudar, alguma coisa no DSP mudou junto.
EXPECTED_BITS = 9600
EXPECTED_SYNC_OFFSETS = (1036, 2210, 5026, 7100, 8275)
EXPECTED_NGHAM_FRAMES = 2  # os outros três são beacons AX.25


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


@pytest.fixture(scope="module")
def recovered_bits() -> list[int]:
    """O WAV real, atravessado pela recuperação de tempo da estação.

    Escopo de módulo: recuperar 8 s custa alguns segundos, e todos os testes
    abaixo olham o mesmo resultado.
    """
    if not FIXTURE.exists():
        pytest.skip(f"fixture ausente: {FIXTURE}")

    with wave.open(str(FIXTURE), "rb") as handle:
        assert handle.getframerate() == SAMPLE_RATE
        assert handle.getnchannels() == 1
        assert handle.getsampwidth() == 2
        raw = handle.readframes(handle.getnframes())

    audio = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0

    # Em blocos, como o serviço faz — e é o mesmo objeto MM em todos eles, de
    # modo que o estado atravessa as fronteiras. Reiniciá-lo a cada bloco
    # perderia a fase e o resultado deixaria de ser reproduzível.
    mm = MM(samp_rate=SAMPLE_RATE, baud=BAUD)
    bits: list[int] = []
    chunk = SAMPLE_RATE * 2

    for start in range(0, len(audio), chunk):
        bits.extend(int(b) for b in mm.decode_stream(audio[start : start + chunk]))

    return bits


# --- a recuperação de tempo --------------------------------------------------


def test_a_contagem_de_bits_bate_com_a_duracao(recovered_bits):
    """8 s a 1200 baud são 9600 bits. Um erro de relógio apareceria aqui antes
    de aparecer em qualquer outro lugar."""
    assert len(recovered_bits) == EXPECTED_BITS


def test_os_bits_nao_ficam_presos_num_valor(recovered_bits):
    """Uma recuperação de tempo que perdeu a trava entrega tudo 0 ou tudo 1, e
    isso ainda passaria numa contagem de bits."""
    uns = sum(recovered_bits) / len(recovered_bits)

    assert 0.35 < uns < 0.65


# --- as convenções do satélite -----------------------------------------------


def test_o_syncword_do_ngham_aparece_onde_foi_medido(recovered_bits):
    offsets = find_all(recovered_bits, expand(NGHAM_SYNC))

    assert tuple(offsets) == EXPECTED_SYNC_OFFSETS


def test_a_convencao_invertida_nao_acha_nada(recovered_bits):
    """A GUARDA DE REGRESSÃO deste arquivo.

    `BA 67 54 7E` expandido MSB-first é o que o simulador emitia e o detector
    procurava. Contra o satélite de verdade ele acha ZERO — e como o simulador
    emitia o mesmo valor errado, nenhum teste sintético podia perceber.

    Se este teste um dia falhar encontrando alguma coisa, alguém reintroduziu
    a inversão em algum lugar do cano.
    """
    assert find_all(recovered_bits, expand(REVERSED_SYNC)) == []


def test_invertido_em_lsb_e_o_mesmo_que_ngham_em_msb(recovered_bits):
    """Os dois valores descrevem a MESMA sequência de bits, em convenções
    opostas. Este teste existe para que a equivalência fique escrita, e
    ninguém precise redescobri-la olhando hexadecimal."""
    assert find_all(recovered_bits, expand(REVERSED_SYNC, lsb_first=True)) == list(
        EXPECTED_SYNC_OFFSETS
    )


def test_o_preambulo_antes_do_sync_e_0xAA(recovered_bits):
    """0xAA = 10101010, como o ngham.c define — e não 0x55, que é o mesmo byte
    com os bits invertidos."""
    first = EXPECTED_SYNC_OFFSETS[0]

    assert recovered_bits[first - 16 : first] == [1, 0] * 8


# --- o enquadramento ---------------------------------------------------------


def test_ha_frames_ngham_com_size_tag_exato(recovered_bits):
    """O que separa "achei um padrão de 32 bits" de "achei um frame".

    Distância de Hamming ZERO contra um codeword de tamanho do NGHam. Os
    outros syncwords desta fixture são beacons AX.25, que o FloripaSat-1
    transmitia alternando com os NGHam — o GRS oficial conta os dois em
    estatísticas separadas.
    """
    exatos = 0

    for offset in find_all(recovered_bits, expand(NGHAM_SYNC)):
        segment = recovered_bits[offset + 32 : offset + 56]
        if len(segment) < 24:
            continue
        value = int("".join(map(str, segment)), 2)
        if any(bin(value ^ tag).count("1") == 0 for tag in NGHAM_SIZE_TAGS):
            exatos += 1

    assert exatos == EXPECTED_NGHAM_FRAMES


def test_os_pacotes_vem_em_pares_ngham_mais_ax25(recovered_bits):
    """A cadência observada: cada transmissão manda um NGHam e, ~1 s depois,
    um AX.25. Serve de âncora — se a contagem de syncwords mudar sem que a
    cadência mude, o que mudou foi detecção, não sinal."""
    offsets = find_all(recovered_bits, expand(NGHAM_SYNC))
    intervalos = [(b - a) / BAUD for a, b in zip(offsets, offsets[1:])]

    assert any(0.8 < intervalo < 1.2 for intervalo in intervalos)
