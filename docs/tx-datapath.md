# Caminho de TX (uplink) do FS-2

Fatia de uplink: **manda o telecomando, recebe a resposta, associa**. O plano está
em `c:\dev\spacelab\fatia-uplink-fs2.md`, e os pares TC → resposta, os estados e
os limites do protocolo em `uplink-pares-e-estados-fs2.md`.

```
TC Generator (:5000)        cria o TC: PING, ACTIVATE_MODULE, DEACTIVATE_MODULE
    │ public.telecommands
TC Scheduler · tc_lifecycle  dono dos status; um TC por vez por satélite
    │ REQ :5593 {"op": "transmit", "telecommand_id"}
grs-uplink                   SLP + HMAC -> NGHam -> GMSK 240 kS/s; freq = 145,9 MHz - Doppler (SUB :5581)
    │ REQ :5559 [header JSON, IQ cf32_le]           grava mission_control.uplink_transmissions
grs-iq-rx (VHF)              profile rx: o USRP N210 (TX pelo mesmo rádio, BURST_ACK)
                             profile rxsim: o grs-sdr-sim, satélite simulado
    │ (no ar) ... resposta do satélite: 0x02 pela VHF, 0x13 pela UHF
cadeia RX de cada rádio      demod -> syncword -> archiver -> grs-telemetry-decoder
    │ decoded_frames, fs2_ping_answer, fs2_tc_feedback
TC Scheduler · tc_lifecycle  casa a resposta com a transmissão -> confirmed / failed / ...
```

## Portas

| Porta | Quem | Contrato |
|---|---|---|
| `5593` | `grs-uplink` (REP, 172.30.0.40) | `{"op": "transmit", "telecommand_id": N}` → `{ok, transmission_id, status, detail, tc_pkt_id, expected_response_pkt_id, tx_freq_hz, doppler_hz}`; `{"op": "health"}` |
| `5559` | rádio VHF (REP, alias `grs-iq-rx`) | o contrato de TX, abaixo |
| `5567` | `grs-sdr-sim` VHF (PUB) | só no simulador: `[b"uhf", quadro NGHam]`, as respostas que descem pela UHF |

## O contrato da :5559

O **mesmo** no `grs-iq-rx/usrp` (o N210) e no `grs-sdr-sim` (o satélite simulado).
O `grs-uplink` não sabe qual dos dois está do outro lado.

**Pedido:** multipart `[header, iq]`.

| Campo do header | |
|---|---|
| `burst_id` | o `id` da linha em `uplink_transmissions` |
| `sample_rate` | `240000` |
| `tx_freq_hz` | já com a correção de Doppler |
| `n_samples` | |

`iq` é complex64 little-endian intercalado (`cf32_le`), como o RX publica.

**Resposta:** JSON `{burst_id, status, started_at, ended_at, actual_freq_hz, detail}`.

| `status` | Significado | O que o Scheduler faz |
|---|---|---|
| `ack` | a rajada saiu inteira. No USRP: o `BURST_ACK` do UHD (prova N1) | `sent` |
| `underflow` | faltou amostra no meio: o satélite recebe um pedaço | fica na fila, tenta de novo |
| `timeout` | sem `BURST_ACK` no prazo | idem |
| `error` | pedido inválido, USRP desconectado, frequência fora da faixa | idem |
| `tx_disabled` | TX desligado no painel do rádio | idem |
| `busy` | outra rajada em andamento | idem |

O rádio só responde **depois** de a rajada sair. O prazo do `grs-uplink` é a duração
da rajada mais `UPLINK_RADIO_TIMEOUT_S`.

## Ligar

| Onde | O quê |
|---|---|
| `.env` | `UPLINK_ENABLED=1`. Sem isso, o Scheduler mantém o `sent` inferido no fim da passagem, como antes da fatia |
| `.env` | `STATION_CALLSIGN`: o indicativo licenciado da estação. O padrão `PY0SIM` é um marcador para o simulador |
| `.env` | `UPLINK_KEYS_FILE`: as chaves de voo, montadas por volume. O padrão são as chaves de **teste** do `grs-uplink`, as mesmas do satélite simulado |
| painel do USRP (8091) | **profile `rx`:** `tx_bind = tcp://*:5559` (já é o padrão de uma instalação nova) e **TX ligado**. Só com carga fantasma ou com comutação T/R e amplificador na frente do receptor |

## Testar no simulador

```powershell
# .env: UPLINK_ENABLED=1
docker compose --profile rxsim up -d --build

# 1. Um TC pelo TC Generator (http://localhost:5000): PING, ou ACTIVATE_MODULE {"module_id": 3}.
# 2. Uma sessão de uplink manual (sem esperar uma passagem real):
curl -X POST http://localhost:5591/api/uplink/session -H "Content-Type: application/json" `
     -d '{"satellite": "<código do satélite>", "duration_s": 300}'
# 3. Acompanhar:
curl http://localhost:5591/api/uplink
```

Ver também:
- **o satélite simulado:** o painel do sim VHF (http://localhost:8090), cartão
  "Satélite simulado". Mostra o TC recebido, o que o OBDH fez, a resposta e o
  residual de Doppler;
- **o status do TC:** a tabela `telecommands` e `execution_logs.details`, com o
  `transmission_id` e o `decoded_frame_id` que provaram cada transição.

Para exercitar os outros desfechos, use o painel do sim:
- **"Falhar o próximo com −2"** → `failed`, com o motivo;
- **"Ignorar o próximo"** → `no_response` depois de `UPLINK_FEEDBACK_TIMEOUT_S`;
- **"TX aceito" desmarcado** → `tx_disabled`; o TC fica na fila.

**Ponta a ponta sem Docker:** `tests/test_uplink_loop_offline_e2e.py`. O TC sobe pelo
`grs-uplink`, chega ao satélite simulado por ZMQ, a resposta desce pelo
`GRSDemodulator` real, e o casamento do `tc_lifecycle` a reconhece.

## O que não está coberto

- **TX real com o N210:** não foi verificado sem o hardware. O checklist da primeira
  rajada com carga fantasma está no README do `grs-iq-rx/usrp`.
- **Tamanho máximo de TC que o TTC2 recebe (TODO-1):** a premissa é sem limite. O
  simulador emula o limite de 80 bytes com `SIM_TC_RX_MAX_BYTES=80`.
- **Telecomandos além do Ping e de Activate/Deactivate Module:** são mais entradas no
  catálogo do `grs-uplink` e no modelo do OBDH do simulador.
- **Comutação T/R e sequência do front-end de RF:** fica para quando a fatia for ao
  hardware (`spacelab-ufsc/grs-rf-front-end-controller`).
