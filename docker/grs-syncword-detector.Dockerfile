# GRS Syncword Detector — biblioteca + serviço (fork em nanosat-gs, GPL v3).
#
# O bloco adotado é uma BIBLIOTECA: syncword_create, syncword_detect,
# syncword_destroy. O que a estação roda é o `service.c` do mesmo repositório
# — nosso código, que embrulha a biblioteca num serviço ZMQ:
#
#   SUB :5555  bits do demodulador, um byte por bit (= bool*, direto)
#   PUB :5558  raw packets  [tópico][cabeçalho JSON][payload empacotado]
#
# O envelope do raw packet é a costura com a metade de decodificação da
# estação, e está definido no cabeçalho do service.c.
#
# REF ADOTADO: branch `station`, que nasce de 01e3d04 e NÃO da `main`. Na
# `main` o syncword.c foi reescrito para busca alinhada a BYTE sem que o
# syncword.h acompanhasse — além de não compilar, é a implementação errada
# para este cano: o que sai do demodulador é um fluxo de bits sem sincronismo
# de byte, e uma busca por fronteira de byte acha o syncword em 1 de cada 8
# passagens. Ver docs/rx-datapath.md.

FROM debian:bookworm-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc \
        make \
        libc6-dev \
        libzmq3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .

RUN make all

# `make check` roda o teste de fumaça: monta o syncword, planta num offset
# DESALINHADO e exige que o detector o ache. É o portão que pega regressão no
# ref adotado — e falha o build, não a passagem.
RUN make check

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        libzmq5 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/grs_syncword /usr/local/bin/grs_syncword

EXPOSE 5558

CMD ["grs_syncword"]
