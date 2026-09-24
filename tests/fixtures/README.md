# Fixtures do caminho de recepção

Duas, e a diferença entre elas é o ponto.

## `fs2-2gfsk-4800.sigmf-*` — sintética

IQ 2GFSK com enquadramento NGHam, gerado pelo `grs-sdr-sim` com semente fixa e
**sem ruído**, gravado pelo `grs-iq-recorder`.

| | |
|---|---|
| Formato | SigMF, `cf32_le` |
| Taxa | 240 kS/s |
| Baud | 4800 (provisório — ver `docs/rx-datapath.md`) |
| Duração | 0,58 s, ~3 rajadas |
| Tamanho | 1,06 MB |

Sem ruído de propósito: qualquer erro de bit no teste é regressão, nunca azar.

Exercita o caminho **inteiro** — gravação, replay, discriminador, filtro
casado, recuperação de tempo, detecção. É a rede de regressão do DSP.

O que ela **não** pode pegar: erro em constante que o simulador e o receptor
compartilhem. Os dois vêm do mesmo repositório e do mesmo documento — se o
valor estiver errado nos dois, eles concordam e o teste fica verde. Foi
exatamente o que aconteceu com o syncword.

## `floripasat1-beacon-1200.wav` — real

Beacon do **FloripaSat-1**, do ar.

| | |
|---|---|
| Formato | WAV, 48 kHz, mono, 16 bits |
| Origem | saída de áudio do gqrx em Narrow FM |
| Frequência | 145.900 MHz |
| Baud | 1200 |
| Duração | 8,0 s |
| Tamanho | 750 KB |
| Conteúdo | 5 syncwords: 2 NGHam + 3 AX.25 |

**Procedência.** Recorte dos primeiros 8 segundos de
`audio/beacon/floripasat_20191220_0951utc_dk3wn.wav`, do repositório
[floripasat/received-data](https://github.com/floripasat/received-data).
Gravado em **2019-12-20 09:51 UTC** pelo radioamador **DK3WN** (JN49lr). A
telemetria decodificada dessa mesma passagem está no `data/beacon.csv`
daquele repositório, a partir de 09:51:22.

O repositório de origem não declara licença. É material do próprio projeto
FloripaSat; a atribuição ao observador fica registrada aqui.

### Por que ela existe

Isto **não é IQ**. É a saída do discriminador de frequência — o gqrx em Narrow
FM já fez essa etapa, e é por isso que o decodificador oficial do SpaceLab
(`gnuradio/udp_decoder_beacon_new.py`) começa direto na recuperação de tempo:

```python
digital.clock_recovery_mm_ff(samp_rate/baudrate, ...)   # 48000/1200 = 40
```

Ela entra no meio do cano, então cobre menos etapas que a sintética. Em troca,
carrega o que nenhum simulador inventa: ruído real, resíduo de Doppler,
desvanecimento, o AGC do receptor agindo, e o relógio de um oscilador que
esteve em órbita.

E carrega, sobretudo, **as convenções do satélite de verdade** — que foi onde
a fixture sintética falhou em nos proteger.

## O bug que a fixture real encontrou

Antes dela, o simulador gerava e o detector procurava `BA 67 54 7E` em MSB.
Concordavam. Contra o sinal real:

| syncword | ordem | ocorrências |
|---|---|---|
| `BA 67 54 7E` | MSB | **0** |
| `5D E6 2A 7E` | MSB | 5 |

O `ngham.c` de referência define `NGH_SYNC[] = {0x5D, 0xE6, 0x2A, 0x7E}` e
`NGH_PREAMBLE = 0xAA`. `BA 67 54 7E` é o mesmo vetor com os bits de cada byte
invertidos — o valor que o documento da fatia carregava.

`test_rx_real_signal.py` congela essa medição, inclusive a asserção de que a
convenção errada acha **zero**.
