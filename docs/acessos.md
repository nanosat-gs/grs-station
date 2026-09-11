# Acessos da estação

Onde cada serviço atende depois de `docker compose up -d`. As portas são as do
`docker-compose.yml`; se você mudou alguma lá, mude aqui também.

## Interfaces web

| O quê | Link | Para quê |
|---|---|---|
| **Painel do operador** | <http://localhost:5590> | Estado do rotor, satélites, agendamentos e o botão de atualizar TLE |
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

No pgAdmin, ao cadastrar o servidor, o host é `postgres` (o nome do serviço na
rede do compose), não `localhost` — o pgAdmin roda dentro do Docker e é de lá
que ele enxerga o banco.

## Portas que não são web

| Porta | Serviço | Protocolo |
|---|---|---|
| `4533` | GRS Manager | rotctld (hamlib) — controle manual do rotor |
| `5580` | Station Manager | ZMQ REP — comandos de rotor e rastreamento |
| `5591` | TC Scheduler | HTTP — API de leitura do plano (é web, mas não é página) |
| `5432` | PostgreSQL | `postgresql://admin:admin@localhost:5432/tc_generator` |

## API do painel — GRS Manager, `5590`

| Endpoint | Método | Devolve |
|---|---|---|
| `/health` | GET | Estado do rotor |
| `/events` | GET | Server-Sent Events, atualiza a cada 2 s |
| `/api/station` | GET | Satélites com posição e próxima passagem |
| `/api/satellite/<código>` | GET | Detalhe de um satélite (ex.: `SAT-001`) |
| `/api/tle/refresh` | POST | Revalida os TLEs no CelesTrak |

```powershell
curl http://localhost:5590/health
curl http://localhost:5590/api/satellite/SAT-001
curl -X POST http://localhost:5590/api/tle/refresh
```

## API de leitura do plano — TC Scheduler, `5591`

De onde o painel tira os satélites e as passagens. O GRS Manager **não abre o
banco**: ele pergunta aqui. Os caminhos são os mesmos de propósito, para que o
cliente seja um repasse de URL — consultar a `5591` direto é a forma de saber
se um problema no painel é dele ou da fonte.

| Endpoint | Método | Devolve |
|---|---|---|
| `/health` | GET | `{"ok": true, "database_available": bool}` |
| `/api/station` | GET | Satélites com posição e próxima passagem |
| `/api/satellite/<código>` | GET | Detalhe, ou `404` se o código não existe |
| `/api/tle/refresh` | POST | Revalida os TLEs no CelesTrak |

```powershell
curl http://localhost:5591/health
curl http://localhost:5591/api/station
```

Com o TC Scheduler parado, a `5590` continua respondendo: `/health` e `/events`
seguem ao vivo (são o rotor) e `/api/station` devolve `200` com
`database_available: false`. Isso é o comportamento correto, não uma falha —
uma passagem em andamento não pode parar porque um serviço de consulta caiu.

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
