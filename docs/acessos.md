# Acessos da estação

Onde cada serviço atende depois de `docker compose up -d`. As portas são as do
`docker-compose.yml`; se você mudou alguma lá, mude aqui também.

## O que sobe com cada comando

| Comando | Sobe |
|---|---|
| `docker compose up -d` | Base: Postgres, pgAdmin, TC Generator, TC Scheduler, Station Manager, GRS Manager (painel), Spectrum Monitor |
| `docker compose --profile rxsim up -d` | Base + recepção **simulada**: simuladores VHF/UHF, demoduladores, detectores, sintetizadores, FFT, archivers e o **Telemetry Decoder** |
| `docker compose --profile rx up -d` | Base + recepção com os **USRP N210** (painéis 8091/8092) e o mesmo resto do `rxsim` |
| `docker compose --profile rtlsdr up -d` | Base + recepção com **RTL-SDR**, só VHF |

Sem profile de recepção, o painel abre normalmente; a aba Telemetria só diz que
não há decodificador.

## Interfaces web

| O quê | Link | Para quê |
|---|---|---|
| **Painel do operador** | <http://localhost:5590> | Rotor, satélites, passagens; a aba Previsão (pular/forçar passagem); a aba **Telemetria** (último General Telemetry do FS-2) e, no detalhe do satélite, recepção e downlinks |
| **Spectrum Monitor** | <http://localhost:8094> | O espectro de cada rádio ao vivo, com o ajuste fino e o contexto da passagem (só lê) |
| Painel do simulador VHF / UHF | <http://localhost:8090> / <http://localhost:8093> | Profile `rxsim`: o rádio e o satélite simulados |
| Painel do USRP VHF / UHF | <http://localhost:8091> / <http://localhost:8092> | Profile `rx`: endereço e configuração de cada N210 |
| **TC Generator** | <http://localhost:5000> | Cadastrar satélites e criar telecomandos |
| **Satélites** | <http://localhost:5000/satellites> | Cadastro com validação de NORAD ID no CelesTrak |
| **pgAdmin** | <http://localhost:5050> | Inspecionar o banco pela interface |

O painel do operador é o **GRS Manager**, na `5590`. A `4533` do mesmo serviço
não abre no navegador: é protocolo rotctld, não HTTP.

## Credenciais (desenvolvimento)

Valem para o ambiente local; vêm do `.env` e são deliberadamente triviais.

| Serviço | Usuário | Senha |
|---|---|---|
| pgAdmin | `admin@spacelab.com` | `admin` |
| PostgreSQL | `admin` | `admin` |

No pgAdmin, o servidor **"SpaceLab"** já vem cadastrado (`docker/pgadmin/servers.json`):

- host `postgres`, o nome do serviço na rede do compose, e não `localhost`, porque o
  pgAdmin roda dentro do Docker;
- banco `tc_generator`, usuário `admin`;
- na primeira conexão ele pede a senha (`admin`); marque *Save password*.

As tabelas da recepção e da telemetria ficam em `tc_generator` → Schemas →
`mission_control`.

O que você cadastra e salva no pgAdmin (servidores, senhas, histórico) fica no
volume `pgadmin_data` e sobrevive à recriação do container.

## Portas que não são web

| Porta | Serviço | Protocolo |
|---|---|---|
| `4533` | GRS Manager | rotctld (hamlib) — controle manual do rotor |
| `5580` | Station Manager | ZMQ REP — comandos de rotor e rastreamento |
| `5591` | TC Scheduler | HTTP — API do plano e das ações do operador (é web, mas não é página; só em 127.0.0.1) |
| `5592` | Telemetry Decoder | HTTP — telemetria decodificada do FS-2, `/api/telemetry/fs2/general_telemetry/latest` e `/api/decoder/stats` (só em 127.0.0.1; profiles de recepção) |
| `5432` | PostgreSQL | `postgresql://admin:admin@localhost:5432/tc_generator` |
| `5556` / `5566` | IQ Receiver VHF / UHF | ZMQ PUB — IQ `cf32_le`, sem tópico |
| `5555` / `5565` | Demodulator VHF / UHF | ZMQ PUB — bits, um byte por bit |
| `5558` / `5568` | Syncword Detector VHF / UHF | ZMQ PUB — `raw_packet` |

Só na rede interna do compose (sem porta publicada):

| Porta | Serviço | Protocolo |
|---|---|---|
| `5581` | Station Manager | ZMQ PUB — `freq.<rádio>`, `doppler.<rádio>`, `offset.<rádio>` |
| `5557` | Frequency Synthesizer (um por rádio) | ZMQ PUB — `tune` |
| `5582` | FFT (um por rádio) | ZMQ PUB — `afc.<rádio>` (medida) e `fft.<rádio>` (espectro) |
| `5583` | Station Manager | ZMQ XPUB — repasse do `fft.*` para o Spectrum Monitor |

## API do painel — GRS Manager, `5590`

| Endpoint | Método | Devolve |
|---|---|---|
| `/health` | GET | Estado do rotor |
| `/events` | GET | Server-Sent Events, atualiza a cada 2 s |
| `/api/station` | GET | Satélites com posição e próxima passagem |
| `/api/satellite/<código>` | GET | Detalhe de um satélite (ex.: `SAT-001`) |
| `/api/passes` | GET | Previsão: todas as passagens, escolhidas ou não, e a recepção/downlinks de cada satélite |
| `/api/tle/refresh` | POST | Revalida os TLEs no CelesTrak |
| `/api/passes/decision` | PUT | Pular, forçar ou desfazer uma passagem |
| `/api/satellites/<código>/reception` | PUT | Liga/desliga a recepção do satélite |
| `/api/satellites/<código>/downlinks` | PUT | Substitui a lista de downlinks |
| `/api/telemetry/latest` | GET | Último General Telemetry do FS-2, repassado do Telemetry Decoder (`configured`/`available` dizem se há decoder e se ele respondeu) |

As rotas de escrita são repasse para o TC Scheduler; sem ele, respondem `503`.

```powershell
curl http://localhost:5590/health
curl http://localhost:5590/api/satellite/SAT-001
curl -X POST http://localhost:5590/api/tle/refresh
```

## API do plano — TC Scheduler, `5591`

De onde o painel tira os satélites e as passagens. O GRS Manager **não abre o
banco**: ele pergunta aqui. Os caminhos são os mesmos de propósito, para que o
cliente seja um repasse de URL — consultar a `5591` direto é a forma de saber
se um problema no painel é dele ou da fonte.

| Endpoint | Método | Devolve |
|---|---|---|
| `/health` | GET | `{"ok": true, "database_available": bool}` |
| `/api/station` | GET | Satélites com posição e próxima passagem |
| `/api/satellite/<código>` | GET | Detalhe, ou `404` se o código não existe |
| `/api/passes` | GET | Todas as passagens previstas, com o motivo de cada uma e a decisão do operador |
| `/api/tle/refresh` | POST | Revalida os TLEs no CelesTrak |
| `/api/passes/decision` | PUT | `{"satellite_code", "aos", "decision": "skip" \| "force" \| null}` |
| `/api/satellites/<código>/reception` | PUT | Liga/desliga a recepção |
| `/api/satellites/<código>/downlinks` | PUT | `{"downlinks": [{name, frequency_hz, enabled}]}` |

Publicada só em `127.0.0.1`: ela escreve e não tem autenticação.

```powershell
curl http://localhost:5591/health
curl http://localhost:5591/api/station
```

Com o TC Scheduler parado, a `5590` continua respondendo: `/health` e `/events`
seguem ao vivo (são o rotor) e `/api/station` devolve `200` com
`database_available: false`. Isso é o comportamento correto, não uma falha —
uma passagem em andamento não pode parar porque um serviço de consulta caiu.

## API da telemetria — Telemetry Decoder, `5592`

Os raw packets dos dois rádios viram telemetria aqui. Sobe com os profiles de
recepção; publicada só em `127.0.0.1`.

| Endpoint | Devolve |
|---|---|
| <http://localhost:5592/api/health> | `{"ok": true, "decoder_version": ...}` |
| <http://localhost:5592/api/telemetry> | Catálogo: tipos de pacote do FS-2, quem já tem decoder, rádio esperado |
| <http://localhost:5592/api/telemetry/fs2/general_telemetry/latest> | O último General Telemetry, campo a campo (cru, convertido e unidade) |
| <http://localhost:5592/api/telemetry/fs2/general_telemetry?limit=20> | Os 20 mais recentes |
| <http://localhost:5592/api/decoder/stats> | Quantos pacotes por status, por tipo e por rádio; quantos pendentes |

Tipo conhecido sem decoder ainda (ex.: `tc_feedback`) responde `501`; os
pacotes dele estão no banco como `not_implemented`.

## Linha de comando

```powershell
# Acompanhar o plano e o rotor ao vivo
docker compose exec tc-scheduler python -m tc_scheduler.monitor --watch

# Exercitar uma passagem sem esperar a órbita
docker compose exec tc-scheduler python tools/station_demo.py prepare --code SAT-001 --norad-id 44885
docker compose exec tc-scheduler python tools/station_demo.py simulate-pass --code SAT-001
docker compose exec tc-scheduler python tools/station_demo.py reset

# Banco pelo terminal
docker compose exec postgres psql -U admin -d tc_generator

# SÓ DESENVOLVIMENTO: esvaziar os dados de TESTE de raw_packets, decoded_frames e
# fs2_general_telemetry (com backup antes, em backups\). Não toca em satélites,
# passagens nem telecomandos. Recusa sem STATION_ENV=desenvolvimento no .env, e
# recusa com receptor de rádio real ligado. Nunca na estação de produção.
.\tools\limpar-dados-de-teste.ps1

# Os últimos raw packets recebidos, com o rádio de cada um
docker compose exec grs-packet-archiver python -m iq_recorder.main packets --limit 20

# A telemetria decodificada: o último General Telemetry e as contagens
docker compose exec grs-telemetry-decoder python -m telemetry_decoder.main latest
docker compose exec grs-telemetry-decoder python -m telemetry_decoder.main stats
```

## Quando algo não abre

```powershell
docker compose ps            # todos devem estar Up; postgres, healthy
docker compose logs -f grs-manager
docker compose up -d         # recria o que estiver faltando
```

Se o container está `Up` e a porta não responde, confira se você não está
tentando a porta errada — a confusão mais comum é abrir a `4533` (rotctld) no
lugar da `5590` (painel).
