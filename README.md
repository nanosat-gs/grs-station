# Estação Terrestre SpaceLab — orquestrador

Sobe a estação inteira com um `docker compose up`. Este repositório **não tem
código de serviço**: cada bloco da estação é um repositório próprio, com a sua
responsabilidade e a sua imagem, e eles conversam só por rede.

A estação tem duas metades:

- **operação** — decide quais passagens rastrear, aponta o rotor e guarda o
  plano e os telecomandos;
- **recepção** — um rádio por faixa (VHF para o beacon, UHF para os dados),
  cada um com a sua cadeia: IQ → bits → raw packets no banco. A sintonia
  acompanha a passagem sozinha: o Doppler é previsto pela órbita e o erro do
  oscilador do satélite é medido no espectro e corrigido (AFC).

```
                  ┌──────────────┐        ┌──────────────────┐
   operador ──────│ TC Generator │        │   TC Scheduler   │
                  │    :5000     │───┐    │  decide o quê    │
                  └──────────────┘   │    │  e quando  :5591 │
                                     ▼    └────────┬─────────┘
                              ┌────────────┐       │ ZMQ 5580: uma ordem por passagem,
                              │  Postgres  │◀──────┤ com os downlinks do satélite
                              │   :5432    │       ▼
                              └────────────┘  ┌──────────────────┐  Rot2Prog
                                     ▲        │  Station Manager │──────────▶ rotor
                  ┌──────────────┐   │        │  rotor, Doppler, │
   operador ──────│ GRS Manager  │───┘        │  ajuste fino     │
                  │ :5590 :4533  │ (via 5591) └──┬───────────▲───┘
                  └──────────────┘               │ :5581     │ :5582
                                                 │ sintonia  │ desvio medido
  - - - - - - - - - - - - - - - - - - - - - - - -│- - - - - -│- - - -  uma cadeia por rádio (VHF, UHF)
                                                 ▼           │
                                   Frequency Synthesizer     │
                                                 │ tune :5557│
                                                 ▼           │
   USRP N210 / SDR Sim ──▶ IQ Receiver ──:5556──┬──▶ FFT ────┘ (e o espectro → Spectrum Monitor :8094)
                                                ├──▶ Demodulator ─:5555─▶ Syncword Detector ─:5558─▶ Packet Archiver ─▶ Postgres
                                                └──▶ IQ Recorder (captura SigMF e replay)
```

O GRS Manager não toca no Postgres: ele lê e age pela API do TC Scheduler.

## Repositórios

Todos em [nanosat-gs](https://github.com/nanosat-gs). A lista que o bootstrap
clona, com a ref de cada um, é o [repos.txt](repos.txt).

| Bloco | Repositório | Papel |
|---|---|---|
| Satellite Tracker | [spacelab-tracking](https://github.com/nanosat-gs/spacelab-tracking) | Biblioteca: SGP4, CelesTrak, passagens, Doppler |
| Station Manager | [grs-station-manager](https://github.com/nanosat-gs/grs-station-manager) | Rotor; conduz a passagem; anuncia a sintonia e fecha o ajuste fino |
| GRS Manager | [grs-manager](https://github.com/nanosat-gs/grs-manager) | Painel do operador e ponte rotctld |
| TC Scheduler | [grs-tc-scheduler](https://github.com/nanosat-gs/grs-tc-scheduler) | Decide o que rastrear; único escritor do banco; API |
| TC Generator | [grs-tc-generator](https://github.com/nanosat-gs/grs-tc-generator) | Fork: cadastro de satélites e telecomandos; dono do schema |
| IQ Receiver | [grs-iq-rx](https://github.com/nanosat-gs/grs-iq-rx) @ `station` | Fork: receptor USRP N210 (`usrp/`) e RTL-SDR (C) |
| Demodulator | [grs-demodulator](https://github.com/nanosat-gs/grs-demodulator) @ `station` | Fork: IQ → bits (GMSK/2GFSK) |
| Syncword Detector | [grs-syncword-detector](https://github.com/nanosat-gs/grs-syncword-detector) @ `station` | Fork: bits → raw packets |
| Frequency Synthesizer | [grs-frequency-synthesizer](https://github.com/nanosat-gs/grs-frequency-synthesizer) @ `station` | Fork: nominal + Doppler + ajuste fino → `tune` |
| FFT | [grs-fft](https://github.com/nanosat-gs/grs-fft) | Espectro e medida do desvio do sinal, por rádio |
| Spectrum Monitor | [grs-spectrum-monitor](https://github.com/nanosat-gs/grs-spectrum-monitor) | Espectro de cada rádio ao vivo (só lê) |
| IQ Recorder | [grs-iq-recorder](https://github.com/nanosat-gs/grs-iq-recorder) | Captura e replay de IQ; arquivador de raw packets |
| SDR Sim | [grs-sdr-sim](https://github.com/nanosat-gs/grs-sdr-sim) | SDR virtual: satélite com Doppler da órbita real |

Os forks são de repositórios do `spacelab-ufsc` (GPL v3) e pinam a branch
`station`, que nasce do ref que de fato roda em cada um — leia
[docs/rx-datapath.md](docs/rx-datapath.md) antes de "atualizar para a `main`".

## Como subir

```powershell
git clone https://github.com/nanosat-gs/grs-station.git
cd grs-station
.\bootstrap.ps1          # clona os blocos em repos/
cp .env.example .env
docker compose up -d --build
```

No Linux ou em CI, `./bootstrap.sh` faz o mesmo.

**Não há submódulos.** O bootstrap lê `repos.txt` e clona; `repos/` está no
`.gitignore`. Para atualizar tudo depois, rode `.\bootstrap.ps1` de novo — ele
busca as atualizações mas nunca faz merge por cima de trabalho local seu.

Isso sobe a metade de operação. A recepção fica em **profiles**, um por fonte
de IQ — uma de cada vez:

| Profile | Fonte de IQ | Para quê |
|---|---|---|
| `rxsim` | `grs-sdr-sim` (VHF e UHF) | Exercitar a recepção inteira, inclusive a sintonia, sem rádio e sem passagem |
| `rx` | USRP N210 (VHF e UHF) | A estação de verdade |
| `rtlsdr` | dongle RTL-SDR (só VHF, sintonia fixa) | Bancada |
| `replay` | uma captura SigMF | Regressão do demodulador e do detector |

```powershell
docker compose --profile rxsim up -d --build
# o simulador imitando a ISS, com a próxima passagem começando agora:
$env:SIM_ORBIT_NORAD=25544; $env:SIM_ORBIT_MODE="next-pass"; docker compose --profile rxsim up -d
```

| Serviço | Onde |
|---|---|
| TC Generator (satélites e telecomandos) | <http://localhost:5000> |
| Painel do operador | <http://localhost:5590> |
| Spectrum Monitor | <http://localhost:8094> |
| Painel do SDR Sim VHF / UHF (`rxsim`) | <http://localhost:8090> / <http://localhost:8093> |
| Painel do USRP VHF / UHF (`rx`) | <http://localhost:8091> / <http://localhost:8092> |
| API do plano | <http://localhost:5591/api/station> |
| pgAdmin | <http://localhost:5050> |

Endpoints, credenciais de desenvolvimento e as portas que não são web estão em
[docs/acessos.md](docs/acessos.md). O índice da documentação é o
[docs/README.md](docs/README.md); a recepção está em
[docs/rx-datapath.md](docs/rx-datapath.md).

## Rádios e frequências

Cada satélite tem uma lista de **downlinks** (nome e frequência), cadastrada no
painel do operador. O Station Manager manda cada downlink ao rádio cuja faixa o
contém (`STATION_RADIOS` no `.env`):

| Rádio | Faixa | Cadeia | FS-2 |
|---|---|---|---|
| VHF | 143–148 MHz | serviços sem sufixo | beacon, 145,9 MHz, 1200 baud |
| UHF | 462–470 MHz | serviços `-uhf` | dados, 468,4 MHz, 4800 baud |

Satélite sem downlink cadastrado é rastreado pelo rotor, mas nenhum rádio
sintoniza. Cada pacote vai ao banco (`mission_control.raw_packets`) com o
rádio de que veio.

## Localização da estação

De onde a estação observa vem das variáveis `GS_*` do `.env`, e só delas. O
TC Scheduler (que prevê as passagens) e o Station Manager (que aponta o rotor)
leem as mesmas variáveis, e o compose repassa aos dois a partir de um único
bloco (`x-ground-station`). Assim o plano e o apontamento não têm como divergir.

| Variável | Hoje | O que é |
|---|---|---|
| `GS_NAME` | `Estação de Teste` | Nome exibido no painel e nos logs |
| `GS_LATITUDE_DEG` | `-23.5505` | Latitude, em graus (sul é negativo) |
| `GS_LONGITUDE_DEG` | `-46.6333` | Longitude, em graus (oeste é negativo) |
| `GS_ALTITUDE_M` | `760` | Altitude, em metros |
| `GS_MIN_ELEVATION_DEG` | `0` | Máscara de elevação: abaixo disso, sem visada útil |

Os valores atuais são **São Paulo, um exemplo** até haver a coordenada real.
Para trocar:

```powershell
# 1. edite as linhas GS_* no .env (decimal com PONTO: -12.9714, não -12,9714)
docker compose config | Select-String GS_   # 2. confira: os dois serviços, mesmos valores
docker compose up -d                        # 3. recria só quem mudou; não precisa de --build
docker compose logs station-manager | Select-String "Estação:"
```

A última linha deve mostrar a coordenada nova. Um valor mal formatado derruba os
dois serviços na subida (`ValueError`). Isso é intencional: uma estação com
coordenada inválida não pode rastrear em silêncio para o lugar errado.

## Desenvolver

```powershell
.\bootstrap.ps1 -Dev     # clona e instala tudo em modo editável
.\test-all.ps1           # suíte de cada repo + os três e2e daqui: rotor, e recepção
                         # contra IQ sintético e contra sinal real do FloripaSat-1

docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build
```

O override de dev monta as árvores de trabalho de `repos/` nos containers.
`docker compose up` sem ele testa **as imagens**, que é o que rodaria numa
máquina de verdade.

Uma ressalva que custa tempo se ignorada: **editar `repos/spacelab-tracking/`
não tem efeito nos containers**. Ela é instalada por git URL durante o build.
Ver as armadilhas no [CLAUDE.md](CLAUDE.md).

## Exercitar o fluxo

```powershell
docker compose exec tc-scheduler python -m tc_scheduler.monitor --watch
docker compose exec tc-scheduler python tools/station_demo.py prepare --code SAT-001 --norad-id 44885
docker compose exec tc-scheduler python tools/station_demo.py simulate-pass --code SAT-001
```

E para ver que as fronteiras são reais:

```powershell
docker compose stop tc-scheduler
curl http://localhost:5590/health        # o rotor continua ao vivo
curl http://localhost:5590/api/station   # 200, com database_available: false
docker compose start tc-scheduler
```
