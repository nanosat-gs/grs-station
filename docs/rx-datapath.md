# Caminho de dados RX — o que foi adotado, e por quê

Documento de decisão dos Épicos A e B da *Fatia Vertical — Caminho de Dados
RX*. Registra o que se descobriu **lendo, compilando e rodando** os
repositórios adotados, a razão de cada ref pinado no `repos.txt`, e os
envelopes ZMQ que a fatia fechou.

Os blocos adotados vivem em **forks sob `nanosat-gs`**, todos na branch
`station`, criada a partir do ref que de fato roda em cada um. A relação de
fork foi preservada, então PR de volta para o `spacelab-ufsc` continua
funcionando.

Leia antes de "atualizar para a `main`": em dois dos três blocos, isso é uma
**regressão**.

## O cano

```
USRP N210 ─▶ grs-iq-rx/usrp ─┐
  (UHD)      250k→240k       │
RTL-SDR ──▶ grs-iq-rx (C) ───┼─ PUB :5556 (cf32_le, 240 kS/s) ─┬─▶ grs-demodulator ── PUB :5555 (bits) ─▶ grs-syncword-detector ─▶ PUB :5558 raw packets
simulador ▶ grs-sdr-sim ─────┤  todos respondem por grs-iq-rx  │
captura ──▶ grs-iq-replay ───┘                                 └──(tap)─▶ grs-iq-recorder ─▶ captura SigMF + índice

Station Manager ─ PUB :5581 [freq][doppler] ─▶ grs-frequency-synthesizer ─ PUB :5557 [tune] ─▶ fonte de IQ (USRP, simulador)

:5558 ─▶ grs-packet-archiver ─▶ Postgres mission_control.raw_packets (todo raw packet, append-only)
```

Uma fonte de IQ por vez, cada uma no seu profile — ver "Profiles" no fim.

| Porta | Quem BINDA | O quê |
|---|---|---|
| 5556 | `grs-iq-rx` | IQ, `cf32_le`, **sem frame de tópico** |
| 5555 | `grs-demodulator` | bits, **um byte por bit** (0x00/0x01), sem tópico |
| 5557 | `grs-frequency-synthesizer` | `[b"tune", <freq Hz ASCII>]` — nominal + Doppler, a cada segundo de passagem |
| 5581 | `station-manager` | `[b"freq", <Hz>]` no início da passagem (repetido a cada 30) e `[b"doppler", <Hz>]` a cada tick |
| 5558 | `grs-syncword-detector` | raw packets: `[tópico][JSON][payload]` |

## Refs pinados, e o motivo de cada um

### `grs-iq-rx` → `station`, a partir de `dev`

A impl. **C/RTL-SDR**, que é a que de fato recebe. A `dev_py` (Python,
Pluto/USRP) é um RX pela metade: herdou wrappers só-TX do
`spacelab-transmitter` e não tem `rx()`.

Confirmado no `main.c`:

- `zmq_bind(zmq_publisher, "tcp://*:5556")` — ele **binda**, todo mundo mais
  conecta;
- publica uma struct de dois `float` (I e Q), **sem cabeçalho e sem tópico** —
  é `complex64` little-endian, o `cf32_le` do SigMF;
- **um `zmq_send` por amostra**, 8 bytes por mensagem. É o que o B1 conserta
  primeiro: nessa forma não segura taxa real, e obrigaria o gravador a um
  `recv()` por amostra.

Compila limpo (dois warnings de variável não usada).

### `grs-demodulator` → `station`, a partir de `fix/demod` (**não** `dev`)

A `dev` **não roda**, e isto foi observado no container, não deduzido:

```
  File "/app/grs_demodulator/grsdemodulator.py", line 28, in <module>
    from gmsk import GMSK
ModuleNotFoundError: No module named 'gmsk'
```

O `__main__.py` põe o diretório **pai** no `sys.path`, mas o import é do
diretório do pacote. E mesmo resolvendo isso, o laço faz
`a, b = gmsk.demodulate(...)` numa função que devolve **três** valores.

Em `fix/demod` os imports são absolutos, `demodulate()` devolve dois valores, e
o buffer é lido com `np.frombuffer(buf, dtype=np.complex64)` — que é a
confirmação, dentro do código, de que o contrato de IQ é `cf32_le`.

**O que estava quebrado em `fix/demod`, e o B2 consertou:**

1. **Não publica.** O PUB :5555 está *bound*, e os bits saem por `print`. Há um
   `# TODO:` no lugar exato.
2. **`connect("tcp://localhost:5556")` hardcoded.** Dentro do container,
   localhost é o próprio container: ele sobe saudável, assina, e fica num
   `recv()` que nunca recebe nada. **Parece vivo e não processa uma amostra
   sequer.** Nenhuma variável de ambiente corrige — exige mudar o código.
3. **A janela de processamento está errada por ~10 000x.** A conta é
   `300 * (self._fs / self._bt) * 8 * 8`, mas `self._bt` é o produto BT (0.5),
   não amostras por símbolo. Dá cerca de **1,8 GB** acumulados antes de
   processar qualquer coisa. Com `fs/baud` no lugar de `fs/bt` seriam 192 kB.
4. **`DEMOD_DEFAULT_SAMPLE_RATE = 48 kHz` é inalcançável no RTL-SDR** — ver
   abaixo.

O miolo é um **discriminador de frequência**, agnóstico entre GMSK e 2GFSK.
Configurar para o FS-2 é baud e BT, não reescrever DSP.

### `grs-syncword-detector` → `station`, a partir de `01e3d04` (**não** `main`)

**A `main` não compila, e seria a implementação errada.** O último commit
(`0c3287d`, "removed bit expansion in favor of bit wise operations in bytes")
reescreveu o `syncword.c` para busca alinhada a **byte** sem que o
`syncword.h` acompanhasse: o header declara `SyncWord` com `bool* bits` e
`syncword_detect(bool*, ...)`; o `.c` declara `uint8_t* bytes` e uma assinatura
diferente.

Mesmo que compilasse, seria errado para este cano: o que sai do demodulador é
um fluxo de bits **sem sincronismo de byte**. Uma busca que só olha fronteiras
de byte acha o syncword em 1 de cada 8 passagens.

Em `01e3d04` a busca é bit a bit, com distância de Hamming e `lsb_first`
configurável — que é o que o Apêndice A da fatia descrevia (o documento estava
lendo o **header**, que a `main` deixou para trás).

**Mas `01e3d04` também não compila como está**, e por um motivo que se lê como
impossível:

```
syncword.c:47:5: error: conflicting types for 'syncword_detect';
                 have 'int(_Bool *, SyncWord *, int,  int)'
syncword.h:36:5: note: previous declaration of 'syncword_detect'
                 with type 'int(_Bool *, SyncWord *, int,  int)'
```

Os dois tipos são **idênticos no texto**. A causa é que o `.c` redeclara
`typedef struct {...} SyncWord;` depois de incluir o `.h`: em C, duas structs
anônimas declaradas separadamente são **tipos distintos**, e toda assinatura
passa a conflitar.

O conserto são três linhas — `<string.h>` faltando, o `typedef` duplicado, e
um `int main()` de sobra que daria símbolo duplicado ao linkar com o serviço —
e hoje é um **commit na `station`** (`37001e6`). Antes dos forks isso vivia
como um *carry patch* aplicado no `docker build`; ter push no fork foi o que
permitiu virar história de verdade.

O teste de fumaça (`test/syncword_smoke.c`, no próprio repositório) roda como
**portão de build** via `make check`:

```
ok: exact match at a misaligned offset -> 132
ok: one bit error, tolerated -> 132
ok: one bit error, not tolerated -> -1
ok: empty stream, nothing found -> -1
```

### `grs-frequency-synthesizer` → `station`, a partir de `master`

`master` e `dev` têm o mesmo conteúdo no upstream: um arquivo, a classe
`FrequencySynthesizer`, sem ponto de entrada. A conta e o protocolo estavam
certos (`tune` = `freq` + `doppler`). A `station` muda três coisas:

- **`main` com os endereços por argumento**, para rodar como processo
  próprio. O README do upstream diz que o Station Manager instancia a classe;
  o diagrama da estação põe o sintetizador no Station Server, ao lado do
  receptor, e o Station Manager no Control Server. Seguimos o diagrama.
- **`freq` repetido não zera o Doppler.** O Station Manager reenvia a nominal
  a cada 30 anúncios, para quem conectou no meio da passagem. No upstream,
  cada reenvio zerava o Doppler e mandava o receptor de volta à nominal por
  ~1 s — com 3 kHz de desvio, um buraco a cada 30 s.
- **Mensagem malformada é descartada**, em vez de encerrar o laço com
  exceção (só `zmq.Again` era tratado).

As duas correções servem a qualquer usuário do upstream: candidatas a PR.

## Correção de Doppler, ponta a ponta

```
TC Scheduler ─ track_satellite(downlink_frequency_hz) ─▶ Station Manager
Station Manager ─ :5581 [freq][doppler] ─▶ grs-frequency-synthesizer ─ :5557 [tune] ─▶ receptor
```

Malha ABERTA: o Doppler é previsto pelo TLE, ninguém mede o sinal. A
frequência de downlink é cadastrada por satélite no painel do operador.

Medido no compose, com o simulador imitando a ISS (Doppler da órbita real,
geometria própria do simulador) e uma passagem sintética do `station_demo.py`:

| Fase | Sinal em relação ao centro | Pacotes íntegros |
|---|---|---|
| sem passagem (sintetizador calado) | −1250 Hz | 0 de 39 |
| passagem rastreada | 0 a 2 Hz | todos, 0 divergentes |
| sintetizador parado no meio | deriva de 16 a 82 Hz em 48 s (receptor fica na última sintonia) | todos |
| sintetizador religado | volta a −4 Hz em ~26 s | todos |

O rotor não sentiu nenhuma das fases: o apontamento não passa pelo
sintetizador.

Coisas a saber:

- **Religado no meio da passagem, ele leva até ~30 s para retomar.** Descarta
  os `doppler` até o Station Manager reenviar o `freq` (a cada 30 anúncios).
  Nesse meio-tempo o receptor fica na última sintonia, que é o certo.
- **O `[doppler]` só sai com o satélite acima da elevação mínima de
  apontamento** (0° por padrão). Numa passagem real isso é o certo; na
  bancada, a passagem sintética aponta para o outro lado da Terra — suba o
  Station Manager com `STATION_POINTING_MIN_ELEVATION=-90`.
- **A frequência cadastrada tem de ser a que o satélite transmite** (no
  simulador, a do FS-2). Diferença ali é um offset que nenhuma correção de
  Doppler tira; o painel do simulador avisa.
- **Fim da passagem: o receptor fica na última sintonia** (até ~3 kHz da
  nominal) até a próxima passagem mandar `freq`. Entre passagens não há o que
  receber.
- **O `grs-iq-rx` em C (RTL-SDR) não tem `tune`.** Por isso o sintetizador
  fica fora do profile `rtlsdr`.
- **USRP:** o `tune_source` vem do `sdr.json` salvo pelo painel; sem arquivo
  salvo, de `GRS_IQ_RX_DEFAULT_TUNE_SOURCE` (o compose aponta para o
  sintetizador). Um "Salvar" com o campo vazio desliga o `tune` de propósito.

## Os envelopes, fechados (Épico B)

### IQ, na :5556

Uma mensagem por bloco, **sem frame de tópico**, payload em `complex64`
little-endian intercalado (`cf32_le`).

Sem tópico de propósito: o demodulador faz um `recv()` simples, e um frame de
tópico na frente viraria a primeira mensagem dele. A impl. Python do `iq-rx`
prefixa `iq_data`, e é exatamente por isso que ela não casa.

Antes o `grs-iq-rx` fazia um `zmq_send` **por amostra** — 8 bytes por
mensagem, um quarto de milhão de mensagens por segundo a 240 kS/s.

### Bits, na :5555

Uma mensagem por janela, sem tópico, **um byte por bit** (0x00 ou 0x01).

Um byte por bit, e não bits empacotados, porque o próximo estágio busca sobre
um `bool*` — que é exatamente este layout. O consumidor faz o cast e roda, sem
desempacotar e sem ordem de bit para errar aqui. Custa 8× a banda: 4,8 kB/s a
4800 baud, contra 1,9 MB/s de IQ entrando.

### Raw packets, na :5558

Três frames: `[tópico "raw_packet"][cabeçalho JSON][payload empacotado]`.

```json
{"seq":0,"bit_offset":290,"bits":512,"bytes":64,
 "max_sync_errors":1,"syncword":"5DE62A7E",
 "bit_order":"msb_first","detected_at":"2026-09-22T12:00:00Z"}
```

O payload tem tamanho **fixo** porque este estágio não sabe onde o frame
termina: o comprimento vive dentro do NGHam, e parsear NGHam é trabalho do
decodificador. Publica-se uma fatia generosa (255 bytes cobrem o maior frame
NGHam) e o decodificador pega o que precisa.

`max_sync_errors` é a **tolerância** em vigor, não a distância medida —
`syncword_detect` devolve só um índice. O nome é esse para ninguém o ler como
qualidade por pacote.

`bit_offset` é a posição absoluta do primeiro bit **depois** do syncword. É o
que permite localizar um pacote que decodifica mal dentro do IQ que o
produziu.

Empacotado aqui e um-byte-por-bit na entrada porque o enquadramento em bytes
**começa** no syncword: antes dele não há fronteira de byte — que é a razão
de a busca ser bit a bit — e depois dele há.

### Os raw packets vão para o banco

PUB não guarda nada: um pacote publicado sem assinante está perdido. O
`grs-packet-archiver` (mesma imagem do `grs-iq-recorder`, comando
`archive-packets`) assina a :5558 e grava cada raw packet em
`mission_control.raw_packets`, append-only: horário de recepção em solo (µs),
`detected_at`, `detector_seq`, `bit_offset`, o payload cru, o SHA-256 dele, o
cabeçalho JSON inteiro e a sessão do arquivador. É o cru que a decodificação
NGHam vai ler — e poderá reler quando mudar.

Banco fora não perde pacote: o lote fica num buffer e é regravado quando o
banco volta. Medido com o Postgres parado 15 s e o simulador transmitindo:
voltou a gravar 3 s depois de o banco subir, sequência do detector sem
buracos.

## O cano provado sem rádio

`tools/inject_iq.py` ocupa o lugar do SDR e publica IQ sintético no envelope
loteado; `tools/collect_packets.py` assina a outra ponta. O DSP da modulação é
o do **próprio demodulador** (a classe `GMSK`), para não escrever um modulador
nosso só para testar o deles.

Resultado de 20 pacotes, com sinal **sem ruído nenhum**:

```
pacotes: 20   byte-exatos: 15   divergentes: 5
```

### O que isso revela, e é o próximo problema a atacar

Os cinco divergentes **não são aleatórios**:

- são sempre o **mesmo** payload errado (`...0405 0607` sai como `...0407 8707`);
- caem sempre no **4º pacote**, com regularidade de relógio;
- o espaçamento entre pacotes é de **803 bits**, quando o frame tem 800.

Três bits de sobra por frame. Cerca de dois vêm da cauda do filtro gaussiano
do modulador (o `inject_iq` gera 40101 amostras onde 800 símbolos × 50 dariam
40000), mas o resto é **deriva do sincronismo de tempo** — e num sinal
sintético, sem ruído, sem Doppler e sem desvio de relógio, o Mueller & Muller
deveria entregar exatamente 800.

Um quarto dos pacotes corrompidos no caso mais fácil possível era o número a
levar para a próxima etapa.

### Resolvido — dois defeitos no demodulador

Medido com `tools/bancada_demod.py` (sinal do `grs-sdr-sim` passando pelo
`GRSDemodulator` real, com as mesmas janelas do serviço ao vivo, conferindo
os 64 bytes de cada pacote):

1. **Cada etapa recomeçava do zero a cada janela.** O sincronismo M&M jogava
   fora onde o último passo de símbolo caía além do fim da janela, e a janela
   seguinte recomeçava até um símbolo inteiro fora de fase — a "deriva do
   sincronismo" acima era isto. O filtro casado (`convolve "same"`), o discriminador e a
   remoção de DC (média da janela) também não guardavam estado.
2. **O ganho do M&M estava em unidade errada.** Escrito por símbolo, aplicado
   a `mu` contado em amostras: 50x fraco demais a 50 amostras por símbolo. O
   laço não rastreava nada. Funcionava no simulador só porque os símbolos dele
   começam alinhados na amostra 0 — por isso a bancada agora atrasa o sinal
   de propósito (`--offset`), senão o defeito passaria de novo por sorte.

Pacotes íntegros em 40 s de sinal (~60 rajadas):

| Cenário | Antes | Depois |
|---|---|---|
| sem ruído | 44 de 59 | 60 de 60 |
| SNR 10 dB | 41 de 59 | 60 de 60 |
| SNR 5 dB (antes) / 3 dB (depois) | 37 de 59 | 60 de 60 |

O "antes" foi medido com os símbolos alinhados na amostra 0 — o caso de SORTE
do código antigo. O "depois" vale para as fases 0, 13, 25 e 37 amostras.

A remoção de DC virou uma média exponencial contínua que só aprende com
amostras de sinal (o ruído dos silêncios não a puxa para zero). Com o
sincronismo já corrigido, contra a média da janela: igual até 300 Hz de
desvio residual (60 de 60), melhor a 500 Hz (52 contra 37).

A única falha que sobra sem ruído é a rajada que começa no instante exato em
que o demodulador liga, antes de o sincronismo convergir. Acima de ~1 kHz de
desvio nenhuma remoção de DC resolve: o Doppler tem de ser corrigido pela
sintonia (Station Manager → sintetizador → `tune`) — ver "Correção de
Doppler, ponta a ponta".

## A armadilha de taxa de amostragem

O RTL-SDR aceita **225001–300000** e **900001–3200000** S/s. Fora disso o
driver **não dá erro** — entrega outra taxa, em silêncio.

O `grs-demodulator` tem `DEMOD_DEFAULT_SAMPLE_RATE = int(48e3)`, que está fora
dos dois intervalos. Ninguém pode simplesmente configurar o `grs-iq-rx` para
48 kS/s: ou o demodulador ganha uma etapa de decimação, ou passa a trabalhar na
taxa do SDR.

Por isso o perfil e o compose usam **240 kS/s**: é válido no RTL-SDR, e
`240000 / 4800 = 50` amostras por símbolo, exato. Repare que o `dev` do
demodulador usava `225001` — o mínimo do RTL-SDR — o que sugere que a versão
original sabia disso e o `fix/demod` regrediu.

É uma decisão de B1/B2 que **não estava no documento da fatia**: o §4 lista o
baud como a última incerteza de RF, mas a taxa de amostragem é uma segunda,
independente dela.

### E o USRP N210 tem a sua própria grade

O rádio da estação é um USRP N210, não um RTL-SDR. Ele só gera
**100 MHz / N**, e 240 kS/s não está nessa grade (÷ 416,67): o UHD também
arredonda **sem erro**. E o demodulador não tolera diferença nenhuma —
medido na `tools/bancada_demod.py`, com o sinal a 240 kS/s e o demodulador
achando que era outra taxa:

| Demodulador configurado para | Diferença | Pacotes íntegros |
|---|---|---|
| 240 000 | 0 | 60 de 60 |
| 239 808 (100 MHz ÷ 417) | 0,08% | ~22 de 60 |
| 240 385 (100 MHz ÷ 416) | 0,16% | 2 de 60 |

Então a taxa do **cano** continua 240 kS/s para todas as fontes, e o
receptor USRP (`grs-iq-rx/usrp`) pede **250 kS/s** ao N210 (exato, ÷ 400) e
reamostra por **24/25** (exato) antes de publicar. Ida e volta
240k → 250k → 240k pelo demodulador real: 60 de 60, de sinal limpo a SNR
3 dB. Se o aparelho entregar uma taxa sem razão exata com a do cano, o
receptor recusa conectar e diz por quê.

## Onde moram os arquivos, e por quê

Os Dockerfiles ficaram aqui por herança de quando os blocos eram consumidos
direto do `spacelab-ufsc`. Com fork já dá para movê-los para dentro de cada
repositório, e manter aqui continua valendo a pena por um motivo: mantém o
diff contra o upstream pequeno, e o PR de volta mais fácil de ler.

As ferramentas de teste do cano também moram aqui, porque são da estação e não
de nenhum bloco:

```
docker/grs-iq-rx.Dockerfile         receptor C/RTL-SDR
docker/grs-iq-rx-usrp.Dockerfile    receptor USRP (python3-uhd), pasta usrp/ do mesmo fork
docker/grs-demodulator.Dockerfile
docker/grs-syncword-detector.Dockerfile
tools/inject_iq.py          publica IQ sintético no lugar do SDR
tools/inject_bits.py        publica bits, para isolar o detector
tools/tap_bits.py           lê a saída de bits do demodulador
tools/collect_packets.py    assina os raw packets
tools/bancada_demod.py      mede pacotes íntegros do demodulador, offline e determinístico
```

O build context é `repos/<bloco>`; só o Dockerfile é externo. Com os forks, o
carry patch e o contexto nomeado do BuildKit deixaram de ser necessários: o
teste de fumaça mudou-se para dentro do repositório do syncword, onde
pertence.

O `grs-iq-recorder` é nosso, então o Dockerfile dele mora no próprio
repositório, como nos outros blocos da estação.

## Profiles

O caminho de recepção **não sobe** num `docker compose up` comum. Um profile
por fonte de IQ; todas bindam a :5556 e respondem pelo nome `grs-iq-rx`,
então nunca sobem juntas e o resto do cano não sabe qual está ali:

| Profile | Fonte de IQ | Quando |
|---|---|---|
| `rx` | `grs-iq-rx-usrp` — USRP N210, python3-uhd, painel em `localhost:8091` | o rádio da estação |
| `rtlsdr` | `grs-iq-rx` — o receptor em C do plano original | quem tiver um dongle |
| `rxsim` | `grs-sdr-sim` — painel em `localhost:8090` | sem hardware |
| `replay` | `grs-iq-replay` — uma captura, sob demanda | regressão offline |

```powershell
docker compose --profile rx up -d --build
# replay, com a fonte ao vivo desligada:
docker compose stop grs-iq-rx-usrp
docker compose run --rm --use-aliases grs-iq-replay replay /app/captures/<nome> --count-packets
```

O receptor USRP fica **de pé sem o rádio** e mostra no painel por que não
conectou. O receptor em C, sem dongle, sai com `EXIT_FAILURE` — e em Docker
Desktop no Windows não há passagem de USB para a VM.

**Por que o replay é um serviço à parte, e não o gravador publicando:** o
demodulador assina um nome só. Assinar dois (fonte + gravador) foi medido: com
um nome que não resolve na lista, o ZMQ não recebeu nada nem do outro — 0
lotes em 5 s, contra 146 sem ele. E o publicador do replay espera a inscrição
do demodulador (XPUB) em vez de uma pausa fixa: com a pausa, dois replays do
mesmo arquivo deram 13 e 9 pacotes; com a espera, a gravação ao vivo e três
replays deram 16, 16, 16 e 16.

## Colisão de porta a observar

A :5555 (saída de bits do demodulador) é a **mesma** que o `grs-modulator`
(uplink) usa para o tópico `tx_data`. Subir RX e TX na mesma estação exige
realocar uma das pontas.

## Licenciamento

GPL v3 nos três adotados. Entram como **processos separados falando ZMQ**, sem
linkagem, o que tende a agregação e não a obra derivada. As nossas
modificações são GPL e vão junto — o que os forks públicos em `nanosat-gs` já
satisfazem.

O `service.c` do detector é exceção parcial: ele **linka** a biblioteca GPL no
mesmo binário, então é obra derivada e é GPL v3 também. Está no mesmo
repositório, sob a mesma licença, e o cabeçalho diz isso.

Confirmar com quem cuida disso antes de fechar qualquer distribuição da
estação.
