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
| **TC Generator** | `edsoncepedi/grs-tc-generator` | Interface web: telecomandos e satélites (5000) |
| **Orquestrador** | `nanosat-gs/grs-station` | Este repo: compose, bootstrap, docs, e2e |

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

Links, credenciais de desenvolvimento e endpoints em `docs/acessos.md`. A
confusão mais comum é abrir a 4533 (rotctld, protocolo hamlib) esperando o
painel, que está na 5590.

Observar o fluxo:
```powershell
docker compose exec tc-scheduler python -m tc_scheduler.monitor --watch
docker compose exec tc-scheduler python tools/station_demo.py prepare --code SAT-001 --norad-id 44885
docker compose exec tc-scheduler python tools/station_demo.py simulate-pass --code SAT-001
```

Testes: `.\test-all.ps1` roda a suíte de cada repo mais o e2e daqui.

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

**A autonomia mora no TC Scheduler.** Ele pontua as passagens por prioridade do
telecomando à espera, depois quantidade de comandos, depois elevação máxima, e
escolhe as que não se sobrepõem (a estação tem um rotor só).

**O TC Scheduler é o único que escreve no banco — e agora é quem o serve.**
Antes o painel do GRS Manager abria a própria conexão para ler o plano: dois
serviços de repositórios diferentes com raw SQL contra o mesmo schema. Agora
quem escreve é quem serve, pela API de leitura na 5591. O GRS Manager passou a
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
- **Satélite sem telecomando à espera não entra no plano.** O Scheduler usa
  `JOIN telecommands`, não `LEFT JOIN`. Ele continua aparecendo no painel com
  posição, porque a posição vem de outra consulta.
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

Em aberto: encoders/moduladores (transmissão real) — enquanto não existirem, o
`sent` do fim da janela é inferência, não confirmação; parametrizar o
`tcp://localhost:5560` do Rotor Manager, agora que a cópia está sob controle;
estreitar a janela de rastreamento para o período de fluxo de dados; mapa de
trajetória no painel; PR para o upstream do TC Generator.
