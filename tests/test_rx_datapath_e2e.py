"""Teste ponta a ponta do caminho de recepção, sem hardware (E3 + D2).

    FileIqSource -> grs-demodulator -> bits -> syncword -> payload

Determinístico por construção: a fixture em `tests/fixtures/` é IQ 2GFSK
sintético **sem ruído**, gravada com semente fixa e versionada junto com o
código. Qualquer erro de bit aqui é regressão, nunca azar.

## Por que o detector de syncword não entra neste arquivo

O detector é um binário C. Ele não roda em processo com o resto, e exigir
Docker faria este teste — que é a rede de regressão do DSP — só rodar em
máquina com container de pé.

A divisão é honesta sobre o que cada metade prova:

- **aqui**: o DSP de verdade (`GRSDemodulator`, o mesmo que a estação roda)
  contra a fixture, e a busca de syncword refeita em Python. Prova que o
  demodulador recupera os bits certos. Roda em qualquer lugar, entra no
  `test-all.ps1`.
- **`docker/` + `tools/`**: o cano inteiro com o serviço C, exercitado pelo
  `collect_packets.py`. Prova que o envelope de raw packet sai como
  combinado.

O que a metade em Python NÃO prova é que o `service.c` empacota certo — e é
por isso que ele tem o próprio portão de build (`make check`), com o teste de
fumaça que planta o syncword num offset desalinhado.
"""

from __future__ import annotations

import pathlib

import numpy as np
import pytest

zmq = pytest.importorskip("zmq")  # noqa: F841  (o demodulador importa zmq no módulo)

from grs_demodulator.grsdemodulator import GRSDemodulator  # noqa: E402
from iq_recorder.adapters.file_iq_source import FileIqSource  # noqa: E402
from iq_recorder.adapters.numpy_psd_view import NumpyPsdView  # noqa: E402

FIXTURE = pathlib.Path(__file__).parent / "fixtures" / "fs2-2gfsk-4800"

# O que o grs-sdr-sim plantou na fixture.
#
# 5D E6 2A 7E é o NGH_SYNC da implementação de referência do NGHam. NÃO
# BA 67 54 7E, que é o MESMO vetor com os bits de cada byte invertidos — o
# valor que o documento da fatia carregava, e que o simulador e o detector
# usavam em acordo mútuo e em desacordo com o satélite. Uma gravação real do
# FloripaSat-1 mostrou a diferença: BA 67 54 7E em MSB acha ZERO pacotes e
# 5D E6 2A 7E acha dezenove.
SYNCWORD = bytes((0x5D, 0xE6, 0x2A, 0x7E))
PAYLOAD = bytes(range(64))
PREAMBLE_BYTES = 32

# Uma janela confortavelmente maior que um frame (802 símbolos). Menor que
# isso e todo pacote atravessa uma borda de processamento — foi o defeito que
# a bancada expôs, e o motivo de este número não ser arbitrário.
WINDOW_SYMBOLS = 2400


def bits_of(data: bytes) -> list[int]:
    """MSB primeiro, a ordem em que o NGH_SYNC do ngham.c está escrito."""
    return [(byte >> (7 - i)) & 1 for byte in data for i in range(8)]


def find_all(haystack: list[int], needle: list[int]) -> list[int]:
    """Busca bit a bit, como o detector faz.

    Bit a bit, e não byte a byte: o que sai do demodulador não tem sincronismo
    de byte nenhum. Uma busca alinhada a byte acharia o syncword em 1 de cada
    8 passagens, e as outras 7 pareceriam um satélite que não transmitiu.
    """
    found = []
    limit = len(haystack) - len(needle)
    index = 0

    while index <= limit:
        if haystack[index : index + len(needle)] == needle:
            found.append(index)
            index += len(needle)
        else:
            index += 1

    return found


def pack(bits: list[int]) -> bytes:
    """Bits -> bytes, MSB primeiro. O enquadramento começa no syncword."""
    usable = (len(bits) // 8) * 8
    out = bytearray(usable // 8)

    for position in range(usable):
        if bits[position]:
            out[position // 8] |= 1 << (7 - (position % 8))

    return bytes(out)


@pytest.fixture(scope="module")
def fixture_present():
    if not FIXTURE.with_suffix(".sigmf-data").exists():
        pytest.skip(f"fixture ausente: {FIXTURE}")


@pytest.fixture(scope="module")
def demodulated_bits(fixture_present) -> list[int]:
    """A fixture inteira, atravessada pelo DSP de verdade.

    Escopo de módulo porque demodular meio segundo de IQ custa alguns
    segundos, e todos os testes abaixo olham o mesmo resultado.
    """
    source = FileIqSource(FIXTURE)
    demod = GRSDemodulator(
        env={
            "GRS_DEMOD_SAMPLE_RATE_HZ": str(int(source.profile.sample_rate_hz)),
            "GRS_DEMOD_BAUD": "4800",
            "GRS_DEMOD_WINDOW_SYMBOLS": str(WINDOW_SYMBOLS),
        }
    )

    buffer = bytearray()
    bits: list[int] = []

    for block in source.blocks():
        buffer.extend(block.data)
        if len(buffer) < demod.window_bytes:
            continue
        usable = (len(buffer) // 8) * 8
        bits.extend(demod._process_samples(bytes(buffer[:usable])))
        del buffer[:usable]

    return bits


# --- a captura ---------------------------------------------------------------


def test_a_fixture_confere_com_o_proprio_hash(fixture_present):
    """Se a fixture mudou, o resto deste arquivo está medindo outra coisa."""
    source = FileIqSource(FIXTURE)  # verify=True por padrão

    assert source.sample_count > 0


def test_a_fixture_declara_o_contrato_de_captura(fixture_present):
    source = FileIqSource(FIXTURE)

    assert source.profile.datatype.value == "cf32_le"
    assert source.profile.sample_rate_hz == 240_000.0
    assert source.metadata["global"]["grs:contract_version"] == "1.0.0"


# --- D2: confirma sinal -------------------------------------------------------


def test_o_espectro_confirma_sinal_no_centro(fixture_present):
    """D2, primeira metade: há sinal, e ele está onde a sintonia diz."""
    source = FileIqSource(FIXTURE)
    summary = NumpyPsdView().summarize(source, source.profile)

    assert summary.has_signal
    assert summary.peak_offset_hz == pytest.approx(0.0, abs=500.0)


# --- E3: o cano ---------------------------------------------------------------


def test_o_demodulador_produz_bits(demodulated_bits):
    assert len(demodulated_bits) > 0
    assert set(demodulated_bits) <= {0, 1}


def test_o_syncword_e_encontrado_em_offset_desalinhado(demodulated_bits):
    """Que o offset NÃO seja múltiplo de 8 é a prova de que a busca bit a bit
    é necessária — e não uma precaução teórica."""
    offsets = find_all(demodulated_bits, bits_of(SYNCWORD))

    assert offsets, "nenhum syncword no fluxo demodulado"
    assert any(offset % 8 != 0 for offset in offsets)


def test_a_contagem_de_frames_bate_com_a_fixture(demodulated_bits):
    """D2, segunda metade. A fixture tem ~0,58 s a 240 kS/s, com frames de 802
    símbolos e 0,02 s de silêncio entre eles — o que dá 3 rajadas."""
    offsets = find_all(demodulated_bits, bits_of(SYNCWORD))

    assert 2 <= len(offsets) <= 4


def test_o_payload_depois_do_syncword_e_o_que_foi_transmitido(demodulated_bits):
    """O teste que fecha a fatia: o cano entrega os BYTES CERTOS.

    Sem ruído na fixture, exigir igualdade exata é legítimo — e é o que torna
    isto uma rede de regressão em vez de uma demonstração.
    """
    offsets = find_all(demodulated_bits, bits_of(SYNCWORD))
    esperado = PAYLOAD[:32]
    acertos = 0

    for offset in offsets:
        start = offset + len(SYNCWORD) * 8
        trecho = demodulated_bits[start : start + len(esperado) * 8]
        if len(trecho) < len(esperado) * 8:
            continue
        if pack(trecho) == esperado:
            acertos += 1

    assert acertos >= 1, (
        "nenhum frame entregou o payload esperado. O syncword foi achado, então "
        "o defeito está depois dele: recuperação de tempo, ordem de bit, ou "
        "enquadramento."
    )


def test_o_preambulo_alterna_antes_do_syncword(demodulated_bits):
    """0xAA a cada bit. Se o preâmbulo sai embaralhado mas o syncword é achado,
    o problema é de recuperação de tempo no começo da rajada — e este teste
    separa esse caso de um defeito de enquadramento."""
    offsets = find_all(demodulated_bits, bits_of(SYNCWORD))
    assert offsets

    offset = offsets[0]
    trecho = demodulated_bits[max(0, offset - 64) : offset]

    if len(trecho) < 64:
        pytest.skip("primeiro syncword perto demais do começo do fluxo")

    transicoes = sum(1 for a, b in zip(trecho, trecho[1:]) if a != b)

    assert transicoes > len(trecho) * 0.7
