# GRS Demodulator — IQ (:5556) -> bits (:5555).
#
# Dockerfile do lado do orquestrador pelo mesmo motivo do grs-iq-rx: é um
# repositório de terceiros (spacelab-ufsc, GPL v3) que adotamos sem ter push.
#
# REF ADOTADO: `fix/demod`, e não `dev`. A branch `dev` não roda:
#   - grsdemodulator.py faz `from gmsk import GMSK`, que só resolve se o
#     diretório do pacote estiver no sys.path — e o __main__.py põe lá o
#     diretório PAI. Com `python -m grs_demodulator` dá ModuleNotFoundError;
#     rodando o arquivo direto, o `from .timing_sync...` do gmsk.py quebra.
#   - o laço desempacota `a, b = gmsk.demodulate(...)`, que devolve TRÊS
#     valores naquela branch — ValueError no primeiro buffer cheio.
# Em `fix/demod` os imports são absolutos, demodulate() devolve dois valores, e
# o buffer é lido com np.frombuffer(dtype=np.complex64) — que é a confirmação,
# no código, de que o contrato de IQ é cf32_le.

FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# numpy/scipy/pyzmq vêm de wheel manylinux no CPython 3.11: sem gcc, sem
# gfortran, sem BLAS para compilar. Por isso a imagem é slim e não "bookworm
# com build-essential" — se algum dia o requirements.txt subir para uma versão
# sem wheel, é aqui que vai doer.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 5555

# ARMADILHA CONHECIDA, e é a primeira coisa que o B2 conserta: o run() tem
# `self._in_socket.connect("tcp://localhost:5556")` HARDCODED. Dentro do
# container, localhost é o próprio container — ou seja, ele sobe saudável,
# assina, e fica bloqueado num recv() que nunca recebe nada. O serviço parece
# vivo e não está processando uma amostra sequer. Não há variável de ambiente
# que corrija isso: exige mudar o código (ver docs/rx-datapath.md, B2).
CMD ["python", "-m", "grs_demodulator"]
