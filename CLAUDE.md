# Contexto do projeto

Estação terrestre do SpaceLab. **Este repositório é o orquestrador**: ele não
tem `src/`. O que ele tem é o `docker-compose.yml` que sobe a estação inteira,
o bootstrap que traz os outros repositórios, e o teste ponta a ponta.

## Os blocos, cada um no seu repositório

| Bloco | Repositório | O que faz |
|---|---|---|
| **Satellite Tracker** | `nanosat-gs/spacelab-tracking` | Biblioteca: SGP4, CelesTrak, previsão de passagens |
| **Station Manager** | `nanosat-gs/grs-station-manager` | Controla o rotor; conduz uma passagem sozinho (ZMQ 5580) |
| **GRS Manager** | `nanosat-gs/grs-manager` | Painel do operador (5590) e ponte rotctld (4533) |
| **TC Scheduler** | `nanosat-gs/grs-tc-scheduler` | Decide o que rastrear; único escritor do banco; API (5591) |
| **TC Generator** | `nanosat-gs/grs-tc-generator` | Interface web: telecomandos e satélites (5000) |
| **Orquestrador** | `nanosat-gs/grs-station` | Este repo: compose, bootstrap, docs, e2e |

### Caminho de dados RX (profile `rx`)

Três blocos **adotados** do `spacelab-ufsc` via **fork em `nanosat-gs`**, todos
na branch `station`, e um bloco nosso. Não sobem num `docker compose up` comum
— ver a armadilha do profile abaixo, e `docs/rx-datapath.md` para o porquê de
cada base.

| Bloco | Repositório | O que faz |
|---|---|---|
| **IQ Receiver** | `nanosat-gs/grs-iq-rx` @ `station` | Bloco SDR. Pasta `usrp/`: o USRP N210 da estação (python3-uhd, reamostra 250k→240k, painel na 8091). Raiz: o receptor C/RTL-SDR. Os dois publicam IQ `cf32_le` na 5556, em lote |
| **Demodulator** | `nanosat-gs/grs-demodulator` @ `station` | IQ -> bits na 5555, um byte por bit |
| **Syncword Detector** | `nanosat-gs/grs-syncword-detector` @ `station` | Biblioteca C + serviço: raw packets na 5558 |
| **Frequency Synthesizer** | `nanosat-gs/grs-frequency-synthesizer` @ `station` | Nominal + Doppler (:5581) -> `tune` na 5557: a correção de Doppler |
| **IQ Recorder** | `nanosat-gs/grs-iq-recorder` | **Nosso.** Captura, replay e índice do fluxo de IQ |
| **SDR Sim** | `nanosat-gs/grs-sdr-sim` | **Nosso.** SDR virtual: substituto do `grs-iq-rx` para testes |

A branch `station` nasce do ref que de fato roda em cada repositório, e não do
default do fork — que veio do upstream e, em dois dos blocos de RF, é a versão
que não roda. A relação de fork foi preservada, então PR de volta continua funcionando.

O **Rotor Manager** deixou de ser repositório consumido: as 88 linhas dele
estão copiadas em `src/mgm8/vendor/` no Station Manager (ver o `UPSTREAM.md`
de lá).

## Sem submódulos

Os blocos chegam por **clone**, não por `git submodule`. `bootstrap.ps1` lê
`repos.txt` e deixa cada um em `repos/`, que é o build context do compose.

```powershell
git clone https://github.com/nanosat-gs/grs-station.git
cd grs-station
.\bootstrap.ps1
cp .env.example .env
docker compose up -d --build
```

`repos/` está no `.gitignore`, e isso **não é opcional**: sem essa linha o git
trata cada clone como gitlink e você reinventa submódulos por acidente.

`.\bootstrap.ps1 -Dev` instala tudo em modo editável (necessário para o e2e e
para `test-all.ps1`). `.\bootstrap.ps1 -Check` confere antes de subir.

## Portas

| Serviço | Porta |
|---|---|
| TC Generator (web) | 5000 |
| pgAdmin | 5050 |
| PostgreSQL | 5432 |
| GRS Manager — rotctld / painel | 4533 / 5590 |
| **TC Scheduler — API de leitura** | **5591** |
| Station Manager (ZMQ REP) | 5580 |
| **IQ Receiver — ZMQ PUB (IQ)** | **5556** |
| **Demodulator — ZMQ PUB (bits)** | **5555** |
| **Syncword Detector — ZMQ PUB (raw packets)** | **5558** |
| Cadeia UHF (`-uhf`): IQ / bits / raw packets | 5566 / 5565 / 5568 |
| Station Manager — ZMQ PUB (freq/doppler) | 5581 (rede interna) |
| Frequency Synthesizer — ZMQ PUB (tune) | 5557 (rede interna) |
| Painel do receptor USRP VHF / UHF (profile `rx`, só 127.0.0.1) | 8091 / 8092 |
| Painel do SDR Sim VHF / UHF (profile `rxsim`, só 127.0.0.1) | 8090 / 8093 |

Links, credenciais de desenvolvimento e endpoints em `docs/acessos.md`. A
confusão mais comum é abrir a 4533 (rotctld, protocolo hamlib) esperando o
painel, que está na 5590.

Observar o fluxo:
```powershell
docker compose exec tc-scheduler python -m tc_scheduler.monitor --watch
docker compose exec tc-scheduler python tools/station_demo.py prepare --code SAT-001 --norad-id 44885
docker compose exec tc-scheduler python tools/station_demo.py simulate-pass --code SAT-001
```

Testes: `test-all.ps1` roda a suíte de cada repo mais os três e2e daqui — o do rotor, o do **caminho de recepção** contra IQ sintético, e o do caminho de recepção contra **sinal real do FloripaSat-1** gravado do ar. Os dois últimos rodam em processo, sem Docker; ver `tests/fixtures/README.md`.

## Decisões de arquitetura, e por quê

**Cada bloco conversa por rede, e só.** ZMQ 5580 para as ordens de rotor e
rastreamento, HTTP 5591 para consultar o plano, Postgres só para quem escreve.
Nenhum repositório importa código de outro; a única dependência de código
compartilhada é a `spacelab-tracking`, instalada por git URL pinada em tag.

**O gpredict foi substituído por tracking próprio.** Ele calcula bem, mas só
através da interface gráfica — não aceita controle programático, o que impedia
qualquer automação. O servidor rotctld continua de pé na 4533 para quem quiser
assumir a antena por um cliente hamlib, mas o painel não reporta essa conexão:
destacá-la sugeriria que ela ainda faz parte do fluxo normal.

**O laço de apontamento em tempo real roda no Station Manager, não no
Scheduler.** Planejar é lento (propagar 24h de N satélites) e apontar é rápido.
Separados, um replanejamento nunca atrasa o rotor, e uma queda do Scheduler no
meio de uma passagem não a interrompe. O Scheduler manda uma ordem por passagem
(`track_satellite`), não um setpoint por segundo.

**A autonomia mora no TC Scheduler.** Toda passagem de satélite ativo com
órbita conhecida é candidata, com ou sem telecomando — o satélite transmite
telemetria sem esperar uplink. Ele pontua por passagem forçada pelo operador,
depois prioridade do telecomando à espera, quantidade de comandos e elevação
máxima, e escolhe as que não se sobrepõem (a estação tem um rotor só). O
operador pula, força ou desfaz passagens e liga/desliga a recepção por
satélite pela aba Previsão do painel; o painel repassa ao Scheduler, que
guarda isso no schema `mission_control` e replaneja em segundos.

**O TC Scheduler é o único que escreve no banco — e agora é quem o serve.**
Antes o painel do GRS Manager abria a própria conexão para ler o plano: dois
serviços de repositórios diferentes com raw SQL contra o mesmo schema. Agora
quem escreve é quem serve, pela API na 5591 (publicada só em 127.0.0.1:
ela também recebe as ações do operador e não tem autenticação). O GRS Manager passou a
ser o único serviço da estação que **não conhece o Postgres** — o mesmo
argumento que já valia para o Station Manager, e pela mesma razão.

**O painel do GRS Manager degrada em vez de falhar.** Sem
`TC_SCHEDULER_API_URL`, ou com o Scheduler fora do ar, ele volta a ser só o
controle de rotor. Uma passagem em andamento não pode parar porque um serviço
de consulta caiu. O cliente HTTP devolve os mesmos dicionários de falha que a
versão de banco devolvia, e por isso a página não mudou.

**O schema do banco é propriedade do TC Generator.** Copiá-lo para cá criaria
duas fontes de verdade que divergem em silêncio (o initdb só roda em volume
vazio, então a divergência só apareceria num `down -v`). Em vez disso, o TC
Scheduler tem o contrato em `docs/schema-contract.md` e o confere no boot.

**O fim da janela marca os telecomandos como `sent`.** Isso afirma mais do que
a estação observa: ela sabe que rastreou a passagem, não que o rádio transmitiu
— não há encoder nem modulador. Foi decisão do operador, ciente do limite,
porque sem isso um comando ficava em `queued` para sempre. Só passagem
`completed` marca `sent`; a `missed` devolve os comandos à fila.

## Armadilhas conhecidas

- **`name: gs-stationmanager` no topo do compose não pode sair.** Sem ele o
  compose deriva o prefixo dos volumes do nome do diretório, e um clone em
  outra pasta monta `grs-station_postgres_data` — vazio. O initdb roda, o
  schema nasce limpo, os containers sobem saudáveis, e **todos os dados somem
  sem uma única mensagem de erro**.
- **Editar `repos/spacelab-tracking/` não tem efeito.** Ela é instalada por git
  URL durante o build, e nem o `docker-compose.dev.yml` a recarrega. Depois de
  mexer nela: taggeie, atualize a tag nos dois `pyproject.toml` (e no
  `ARG TRACKING_REF` dos dois Dockerfiles), e rebuilde. A falha é silenciosa —
  o container simplesmente segue com o código antigo.
- **Pinar `@main` em vez de tag faz o Docker servir cache velho para sempre.**
  A linha `RUN pip install` não muda, a layer é reaproveitada, e a correção
  nunca chega. Sempre tag.
- **As tags da `spacelab-tracking` precisam bater entre Station Manager e TC
  Scheduler.** O payload de `track_satellite` é `OrbitalData.to_json()`; se os
  dois desserializarem com versões incompatíveis, a falha aparece no meio de
  uma passagem, não no boot. `bootstrap.ps1 -Check` compara os dois.
- **`docker-entrypoint-initdb.d` só roda em volume vazio.** Mudança de schema
  exige `ALTER TABLE` manual ou `docker compose down -v` (que **apaga** os
  dados).
- **`--rotor mock` no Docker.** O `RotorManager` copiado tem o socket SUB fixo
  em `tcp://localhost:5560`, o que não funciona entre containers. Hardware real
  e simulador continuam fora do Docker.
- **Cópias antigas do TC Generator.** Depois do split, `repos/grs-tc-generator`
  é a que constrói. O clone avulso em `../grs-tc-generator` e o
  `services/grs-tc-generator` do monorepo arquivado **não têm efeito** —
  apague-os para não editar o arquivo errado.
- **CelesTrak responde 404 com corpo `No GP data found`** para ID inexistente.
  Checar o corpo antes de `raise_for_status`, senão "não existe" (que deve
  bloquear) vira "site fora do ar" (que deve apenas avisar).
- **Coordenadas da estação são um exemplo** (São Paulo) nas variáveis `GS_*`.
  Trocar antes de qualquer uso real, e **só no `.env`**: o compose as declara
  uma vez em `x-ground-station` e as repassa ao TC Scheduler e ao Station
  Manager. Não reescreva `GS_*` dentro do `environment:` de um serviço só: é
  assim que o plano e o apontamento passam a divergir sem erro nenhum.
- **Satélite sem passagem planejada: confira a aba Previsão.** Ela mostra o
  motivo de cada passagem (perdeu o conflito, pulada, recepção desligada).
  Com a recepção desligada, só entram passagens com telecomando ou forçadas.
- **Sintonia só sai para downlink cadastrado.** Sem downlink o rotor segue a
  passagem, mas o Station Manager não publica nada na 5581. Com downlinks,
  cada um vai ao rádio cuja faixa o contém (`STATION_RADIOS`) e sai no canal
  dele: `freq.vhf`/`doppler.vhf`, `freq.uhf`/... O `[doppler]` sai a cada
  tick com o satélite acima OU abaixo do horizonte; a elevação mínima só
  decide se o ROTOR se move.
- **Uma cadeia de recepção por rádio, todos atrás do mesmo rotor.** Os
  serviços sem sufixo são a cadeia VHF (beacon do FS-2, 145,9 MHz, 1200
  baud); os `-uhf`, a de dados (468,4 MHz, 4800 baud). Cada pacote vai ao
  banco com a coluna `radio`.
- **Quem publica ZMQ tem IP fixo, e isso não é enfeite.** O ZMQ resolve o
  nome uma vez e reconecta no IP antigo. Sem IP fixo, recriar os dois
  detectores juntos fez o arquivador UHF gravar pacotes do VHF marcados como
  "uhf", sem erro nenhum. Mapa de IPs no fim do `docker-compose.yml`; um
  serviço novo que publica ZMQ precisa de `ipv4_address`.
- **Uma fonte de IQ por vez em cada cadeia: `rx` (USRP N210), `rtlsdr`
  (dongle, só VHF), `rxsim` (simulador), `replay` (captura).** As fontes de
  uma cadeia respondem pelo mesmo nome (`grs-iq-rx`, `grs-iq-rx-uhf`) e
  dividem o MESMO IP fixo: subir duas juntas agora falha com "Address already
  in use", em vez de as duas disputarem a porta em silêncio. O demodulador, o detector e o gravador não
  sabem qual está do outro lado, que é o ponto. Ver "Profiles" em
  `docs/rx-datapath.md`.
- **O demodulador assina UM nome, e isso é deliberado.** Assinar dois
  (fonte + gravador) foi medido: com um nome que não resolve na lista, o ZMQ
  não recebe nada nem do outro. Por isso o replay é o serviço
  `grs-iq-replay`, rodado com `docker compose run --rm --use-aliases`.
- **A taxa do cano é 240 kS/s para toda fonte, e o demodulador não tolera
  diferença.** 0,08% já derruba ~65% dos pacotes. O N210 não gera 240 kS/s
  (só 100 MHz / N): o receptor USRP pede 250 kS/s e reamostra 24/25. Não
  "simplifique" pedindo 240k direto ao N210.
- **O receptor USRP fica de pé sem o rádio**, com o motivo no painel
  (`localhost:8091`). O receptor em C, sem dongle, sai com `EXIT_FAILURE` — e
  em Docker Desktop no Windows não há passagem de USB para a VM.
- **Meça o demodulador com a fase de símbolo variando.** Um em cada quatro
  pacotes saía corrompido porque o M&M recomeçava a cada janela e tinha o
  ganho 50x fraco (corrigido no `grs-demodulator` 8b6282e). O defeito passava
  despercebido porque os símbolos do `grs-sdr-sim` começam alinhados na
  amostra 0. `tools/bancada_demod.py` atrasa o sinal (`--offset`) e confere
  os 64 bytes de cada pacote; use-a antes e depois de qualquer mudança no DSP.
  O `collect_packets.py` confere só 16 bytes e não pegava o erro.
- **Rebuild depois de mexer num bloco de RF.** `docker compose --profile rx
  build <serviço>`. O `docker-compose.dev.yml` NÃO monta os três adotados
  (dois são C, e montar o Python esconderia o ref pinado), então uma edição
  em `repos/` não aparece sem rebuild — e o serviço segue rodando o código
  antigo, em silêncio.
- **O syncword do NGHam é `5D E6 2A 7E`, não `BA 67 54 7E`.** Os dois são o
  mesmo vetor com os bits de cada byte invertidos, e o segundo circulou no
  documento da fatia. Contra sinal real do FloripaSat-1, `BA 67 54 7E`
  expandido MSB-first acha **zero** pacotes. O preâmbulo é `0xAA`, não `0x55`.
  O erro sobreviveu porque o nosso simulador emitia o mesmo valor errado que o
  detector procurava — transmissor e receptor concordando e ambos discordando
  do satélite. `tests/test_rx_real_signal.py` guarda contra a reincidência.
- **Não "atualize para a `main`" os blocos de RF.** Em dois dos três é
  regressão: a `main` do `grs-demodulator` e a `dev` não rodam, e a `main` do
  `grs-syncword-detector` não compila E trocou a busca bit a bit por uma
  alinhada a byte — que erra o syncword em 7 de cada 8 casos, porque o que sai
  do demodulador não tem sincronismo de byte. As refs pinadas em `repos.txt`
  foram escolhidas compilando cada uma. Ver `docs/rx-datapath.md`.
- **O RTL-SDR não aceita 48 kS/s.** Os intervalos válidos são 225001–300000 e
  900001–3200000 S/s, e fora deles o driver **não dá erro** — entrega outra
  taxa, calado. A constante `DEMOD_DEFAULT_SAMPLE_RATE` do `grs-demodulator` é
  48 kHz, ou seja, inalcançável: ou ele ganha decimação, ou passa a trabalhar
  na taxa do SDR. Por isso o compose usa 240 kS/s (válido, e 50 amostras por
  símbolo exatas a 4800 baud).
- **A frequência RX do `.env` é um EXEMPLO**, como as coordenadas `GS_*`.
  145.9 MHz é a beacon do **FS-1**. A modulação do FS-2 está confirmada
  (2GFSK, syncword `5D E6 2A 7E`); a frequência e o baud dependem da
  coordenação IARU. Trocar antes de qualquer campanha de gravação real.
- **A :5555 colide com o `grs-modulator`** (uplink, tópico `tx_data`). Subir
  RX e TX na mesma estação exige realocar uma das pontas.
- **O card do satélite no painel atrasa até ~45 s.** Ele lê
  `satellite_tracking_status` (escrito a cada 30 s) e a página busca a cada
  15 s, enquanto o rotor vem ao vivo. O número do rotor é o atual.

## Convenções

- Comentários e mensagens de commit em português; código e identificadores em
  inglês. O TC Generator (upstream de terceiros) usa inglês também nos
  comentários — seguir o arquivo em que se está mexendo.
- Cada repositório tem o seu próprio `CLAUDE.md` com as armadilhas dele. Este
  aqui é o transversal: o que só se vê com a estação inteira montada.
- Testes acompanham comportamento, não implementação.

## Estado e próximos passos

Feito: split em repositórios independentes com história preservada; API de
leitura no TC Scheduler e o GRS Manager sem acesso ao banco; painel único
(template com a identidade do dashboard do Station Manager) e Doppler no
tracking, trazidos da branch da Laura; Rotor Manager
copiado para dentro do Station Manager; bootstrap sem submódulos; verificação
do contrato de schema no boot.

Feito nos Épicos A e B da fatia de RX: os três blocos adotados entraram por
fork em `nanosat-gs`, branch `station`, com refs escolhidas lendo e compilando
o código; o `grs-iq-recorder` nasceu com esqueleto hexagonal, `CaptureProfile`
`grs-rx-fs2` e contrato SigMF versionado; e **o cano de recepção passa sinal
ponta a ponta** — IQ loteado, bits publicados, e um serviço em volta do
detector que emite raw packets na 5558. Provado sem rádio, com IQ sintético.

Depois: o `grs-iq-recorder` grava, reproduz, importa WAV do gqrx, conta os
pacotes do detector (`--count-packets`) e tem adapter para `rtl_tcp`; o
replay passa pelo cano de verdade (`grs-iq-replay`: gravação e três replays
deram 16, 16, 16, 16 pacotes); o bloco SDR tem receptor para o USRP N210
(python3-uhd, reamostragem 250k→240k, painel de configuração em
http://localhost:8091), ainda sem o rádio para validar; o `grs-sdr-sim` tem
painel (http://localhost:8090) com modo de um pacote por pedido; o
demodulador entrega 60 de 60 pacotes íntegros na bancada, até SNR 3 dB.

Em aberto na fatia, e nenhum depende de código: validar com o N210 físico
(IP, imagem de FPGA compatível com o UHD 4.3, UDP atrás do NAT do Docker);
o baud real do FS-2 (coordenação IARU); e a confirmação do licenciamento GPL
antes de distribuir.

Passagens de recepção: o TC Scheduler rastreia toda passagem, não só as com
telecomando; o operador pula/força/desfaz passagens e cadastra a frequência
de downlink pelo painel (aba Previsão), e a frequência chega ao Station
Manager no `track_satellite` e sai como `[freq]` na 5581 — o elo 1 do
Doppler. Próxima task desse lado: o operador escolher, no TC Generator, se um
telecomando vai automaticamente para a próxima passagem ou é atribuído à mão.

O `grs-sdr-sim` imita um satélite de verdade: Doppler da órbita real (NORAD
ou TLE, pelo painel ou `SIM_ORBIT_NORAD`), calado abaixo do horizonte, em
tempo real ou "próxima passagem começando agora". A geometria é própria, não
a da spacelab-tracking, e o painel compara com o Doppler que o Station
Manager anuncia na 5581 (concordam em 1–5 Hz). Medido: no início de uma
passagem (+3,3 kHz), sintonia fixa entrega 1 de 16 pacotes; sintonizando em
portadora + Doppler, todos.

Dois rádios, uma passagem: o FS-2 desce o beacon em 145,9 MHz (1200 baud)
e os dados em 468,4 MHz (4800 baud) — valores do firmware do TTC 2.0 e da
coordenação IARU do GOLDS-UFSC. Cada satélite tem uma lista de downlinks
(painel do operador), o Station Manager calcula o Doppler de cada um (o da
referência pela spacelab-tracking, os outros por proporção, para o meio do
intervalo entre ajustes) e um sintetizador por rádio sintoniza a sua cadeia.
Medido com a ISS: as duas cadeias a ≤1 Hz do centro e todos os pacotes nas
duas, contra 0 sem correção; estação e simulador concordam em 0–1 Hz. Pelo
caminho: o detector de syncword pulava o pacote seguinte quando ele caía
dentro da fatia de 255 bytes do anterior (metade dos pacotes do beacon a
1200 baud), e a troca de IP descrita nas armadilhas.

Correção de Doppler automática, ponta a ponta: o `grs-frequency-synthesizer`
(fork, branch `station`) assina a :5581, soma nominal + Doppler e publica o
`tune` na :5557, que o simulador e o USRP seguem por padrão. Medido com a
ISS: sinal a 0–2 Hz do centro e todos os pacotes durante a passagem, contra
0 de 39 sem correção; parar o sintetizador no meio não derruba rotor nem
receptor, e religado ele retoma em ~30 s. Detalhes e armadilhas em
`docs/rx-datapath.md`, "Correção de Doppler, ponta a ponta".

Os raw packets da :5558 são gravados crus no Postgres
(`mission_control.raw_packets`) pelo `grs-packet-archiver`, append-only, com
o horário de recepção em solo — nenhum pacote de passagem real se perde
enquanto o decodificador não existe, e ele poderá reprocessar o histórico.

Próxima fatia: o decodificador NGHam (size tag, Reed-Solomon, payload,
telemetria) — por desenho, o documento da fatia põe a decodificação fora
dela. Ele pode ler da :5558 ao vivo ou de `mission_control.raw_packets`. O
`grs-sdr-sim` ainda não gera quadros NGHam de verdade (manda 00 01 02 ... sem
size tag nem RS).

Em aberto: encoders/moduladores (transmissão real) — enquanto não existirem, o
`sent` do fim da janela é inferência, não confirmação; parametrizar o
`tcp://localhost:5560` do Rotor Manager, agora que a cópia está sob controle;
estreitar a janela de rastreamento para o período de fluxo de dados; mapa de
trajetória no painel; PR para o upstream do TC Generator.
