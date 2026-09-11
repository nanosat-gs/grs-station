# Estação Terrestre SpaceLab — orquestrador

Sobe a estação inteira com um `docker compose up`. Este repositório **não tem
código de serviço**: cada bloco da estação é um repositório próprio, com a sua
responsabilidade e a sua imagem, e eles conversam só por rede.

```
                  ┌──────────────┐        ┌──────────────────┐
   operador ──────│ TC Generator │        │   TC Scheduler   │
                  │    :5000     │───┐    │  decide o quê    │
                  └──────────────┘   │    │  e quando  :5591 │
                                     ▼    └────────┬─────────┘
                              ┌────────────┐       │ ZMQ 5580
                              │  Postgres  │◀──────┤ (uma ordem
                              │   :5432    │       │  por passagem)
                              └────────────┘       ▼
                                     ▲    ┌──────────────────┐
                  ┌──────────────┐   │    │  Station Manager │
   operador ──────│ GRS Manager  │───┘    │  aponta o rotor  │
                  │ :5590 :4533  │        └────────┬─────────┘
                  └──────┬───────┘                 │ Rot2Prog
                         │ HTTP 5591               ▼
                         └──────────────────►  rotor
```

O GRS Manager não toca no Postgres: a seta dele vai para a API do TC Scheduler.

## Repositórios

| Bloco | Repositório |
|---|---|
| Satellite Tracker (biblioteca) | [nanosat-gs/spacelab-tracking](https://github.com/nanosat-gs/spacelab-tracking) |
| Station Manager | [nanosat-gs/grs-station-manager](https://github.com/nanosat-gs/grs-station-manager) |
| GRS Manager | [nanosat-gs/grs-manager](https://github.com/nanosat-gs/grs-manager) |
| TC Scheduler | [nanosat-gs/grs-tc-scheduler](https://github.com/nanosat-gs/grs-tc-scheduler) |
| TC Generator | [edsoncepedi/grs-tc-generator](https://github.com/edsoncepedi/grs-tc-generator) |

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

| Serviço | Onde |
|---|---|
| TC Generator (criar telecomandos) | <http://localhost:5000> |
| Painel do operador | <http://localhost:5590> |
| API de leitura do plano | <http://localhost:5591/api/station> |
| pgAdmin | <http://localhost:5050> |

Endpoints, credenciais de desenvolvimento e as portas que não são web estão em
[docs/acessos.md](docs/acessos.md). O desenho do painel está em
[docs/architecture/painel-do-operador.md](docs/architecture/painel-do-operador.md).

## Desenvolver

```powershell
.\bootstrap.ps1 -Dev     # clona e instala tudo em modo editável
.\test-all.ps1           # suíte de cada repo + o teste ponta a ponta daqui

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
