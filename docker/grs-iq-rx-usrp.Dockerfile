# GRS IQ RX — receptor USRP (python3-uhd), com painel de configuração.
#
# Build context: repos/grs-iq-rx (fork nanosat-gs, branch station). Só a
# pasta usrp/ entra aqui; o receptor C/RTL-SDR do mesmo repositório tem o
# próprio Dockerfile (grs-iq-rx.Dockerfile).
#
# Debian puro, e não python:3.11-slim: o python3-uhd vem do apt e só é
# importável pelo Python DO SISTEMA (/usr/bin/python3). Numa imagem
# python:3.11-slim o módulo fica invisível para o python3 que ela usa —
# confirmado, e a falha só apareceria no `import uhd`, em produção.
#
#   PUB  :5556   IQ cf32_le, um lote por mensagem, sem tópico
#   SUB  :5557   tune (opcional)
#   HTTP :8091   painel de configuração

FROM debian:bookworm-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# uhd-host traz uhd_find_devices, uhd_images_downloader e uhd_image_loader.
# As imagens de FPGA NÃO são baixadas no build: são centenas de MB e a versão
# certa depende do firmware do rádio físico — é passo de setup do operador.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3-uhd \
        uhd-host \
        python3-pip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY usrp/pyproject.toml ./
COPY usrp/src/ ./src/

# --break-system-packages: Debian 12 é "externally managed" (PEP 668) e a
# imagem existe só para este pacote. numpy<2 vem do pyproject (o libpyuhd do
# Debian quebra com numpy 2.x).
RUN pip3 install --break-system-packages --no-cache-dir -e .

RUN mkdir -p /app/config
VOLUME ["/app/config"]

EXPOSE 5556 8091

CMD ["python3", "-m", "grs_iq_rx_usrp"]
