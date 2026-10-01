# GRS Frequency Synthesizer — freq/doppler (:5581) -> tune (:5557).
#
# Fork de spacelab-ufsc/grs-frequency-synthesizer (GPL v3), branch `station`.
# O upstream é só a classe, sem ponto de entrada; a `station` acrescenta o
# `main`, para rodar como processo próprio — no diagrama da estação ele mora
# no Station Server, ao lado do receptor, e não dentro do Station Manager.
#
# A `station` também corrige o que faria o receptor perder pacotes: no
# upstream, cada `freq` reenviado pelo Station Manager (a cada 30 anúncios)
# zerava o Doppler e devolvia o receptor à nominal por ~1 s. Ver o docstring
# de frequency_synthesizer.py.

FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# pyzmq vem de wheel manylinux: imagem slim, sem compilador.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY frequency_synthesizer.py ./

EXPOSE 5557

CMD ["python", "frequency_synthesizer.py"]
