# Documentação — Estação Terrestre SpaceLab

Documentação transversal da estação: o que só se vê com todos os blocos
montados juntos. O que é de um bloco só (como rodar, interfaces, armadilhas)
está no README e no `CLAUDE.md` do repositório dele — a lista está no
[README do orquestrador](../README.md#repositórios).

## Comece por aqui

| Documento | Conteúdo |
|-----------|----------|
| [A estação como ela é hoje](architecture/estacao-hoje.md) | Segmentos, quem é dono de quê, uma passagem do plano ao pacote, os contratos entre repositórios |
| [Acessos](acessos.md) | Links, portas, credenciais de desenvolvimento e APIs |
| [Caminho de dados RX](rx-datapath.md) | Recepção: forks adotados e o porquê de cada ref, envelopes ZMQ, correção de Doppler, dois rádios, ajuste fino (AFC), profiles |
| [Painel do operador](architecture/painel-do-operador.md) | O painel único e o que o operador comanda nele |
| [Controle de rotor](rotor-control.md) | Pipeline gpredict → GRS Manager → Station Manager → Rotor Manager, setup e troubleshooting |
| [Follow-up: frame e aprovação de TC](architecture/tc-followup-frame-e-aprovacao.md) | Especificação das duas peças que vão para o fork do TC Generator |

## Proposta original (histórico)

O desenho do **MGM8**, de julho de 2026, antes do split em repositórios. Vale
como registro das intenções; a implementação divergiu em pontos importantes,
listados no fim de [A estação como ela é hoje](architecture/estacao-hoje.md#onde-o-implementado-diverge-da-proposta-original).

| Documento | Conteúdo |
|-----------|----------|
| [Visão geral da arquitetura](architecture/overview.md) | Contexto no ecossistema GRS, responsabilidades e fronteiras previstas |
| [Camadas da aplicação](architecture/application-layers.md) | Arquitetura hexagonal — ainda vale para o Station Manager |
| [Diagrama de componentes](architecture/components.md) | Componentes internos previstos para o MGM8 |
| [Diagrama de implantação](architecture/deployment.md) | Nós físicos, rede, portas propostas |
| [Integração com subsistemas](architecture/integration.md) | Formatos de mensagem propostos |
| [Casos de uso](architecture/use-cases.md) | Atores, casos de uso e diagramas UML |
| [Modelo de banco de dados](database/README.md) | O schema `station_manager` proposto (não implementado) |

## Referências

- [Arquitetura de software GRS — SpaceLab](https://spacelab-ufsc.github.io/grs-doc/software.html)

## Convenções

- **Control Desktop** — o que o operador vê: GRS Manager, Spectrum Monitor, TC Generator
- **Control Server** — decisão e dados: TC Scheduler, Station Manager, PostgreSQL, arquivador de pacotes
- **Station Server** — RF: receptores, sintetizadores, FFT, demoduladores, detectores, gravador
