# GRS IQ Receiver (impl. C / RTL-SDR) — primeiro bloco do caminho de dados RX.
#
# POR QUE ESTE DOCKERFILE MORA AQUI, E NÃO NO REPO DO BLOCO.
# Ao contrário dos cinco blocos da estação, `grs-iq-rx` é um repositório de
# TERCEIROS (spacelab-ufsc, GPL v3) que nós apenas adotamos. Não temos push
# nele, então o empacotamento fica do lado do orquestrador. O build context
# continua sendo repos/grs-iq-rx (ver docker-compose.yml); só o Dockerfile é
# nosso. Quando houver fork em nanosat-gs (ver docs/rx-datapath.md), este
# arquivo se muda para lá e esta seção some.
#
# O que ele faz: abre o RTL-SDR, sintoniza, converte cada par de bytes do
# dongle em {float32 I, float32 Q} e publica num PUB ZMQ que ele mesmo BINDA
# em :5556. É esse formato — complex64 little-endian intercalado, `cf32_le` no
# vocabulário do SigMF — que o demodulador e o gravador consomem.

FROM debian:bookworm-slim AS build

# librtlsdr-dev e libzmq3-dev são as duas únicas dependências: o Makefile linka
# com -lrtlsdr -lzmq e mais nada além de pthread/libm.
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc \
        make \
        libc6-dev \
        librtlsdr-dev \
        libzmq3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .

# O Makefile usa BUILD_DIR=$(CURDIR) por padrão e deixa o binário em
# /src/grs_iq_rx.
RUN make

FROM debian:bookworm-slim

# Só as bibliotecas de runtime: sem gcc, sem headers. A imagem final não
# compila nada.
RUN apt-get update && apt-get install -y --no-install-recommends \
        librtlsdr0 \
        libzmq5 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/grs_iq_rx /usr/local/bin/grs_iq_rx

EXPOSE 5556

# Sem SDR presente o programa faz rtlsdr_open() falhar e sai com EXIT_FAILURE.
# Isso é o comportamento certo (o container cai, isolado, sem derrubar mais
# ninguém) e é por isso que o serviço fica atrás do profile `rx` no compose:
# numa máquina de desenvolvimento sem dongle, `docker compose up` não deve
# ficar vermelho por causa de hardware que ninguém tem ali.
#
# Os parâmetros reais (frequência, taxa, ganho) vêm do `command:` do compose.
# `-v` é deliberado: sem ele TODO erro é silencioso — o main.c só escreve em
# stderr quando verbose está ligado, inclusive as falhas de abertura do
# dispositivo e de bind do ZMQ.
CMD ["grs_iq_rx", "-v"]
