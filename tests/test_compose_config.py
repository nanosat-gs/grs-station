"""Salvaguarda de configuração do docker-compose.

O nome do projeto (`name:` no topo do docker-compose.yml) fixa o prefixo dos
volumes nomeados do Postgres e do cache de tracking. Sem ele, o Compose deriva
o prefixo do nome do DIRETÓRIO onde o repositório foi clonado — e um clone em
outra pasta passaria a montar volumes vazios, com o Postgres subindo saudável
sobre um schema recém-criado e nenhuma mensagem de erro avisando que os dados
antigos (satélites, telecomandos, histórico de execução) ficaram para trás.

Esse é exatamente o tipo de regressão silenciosa que não aparece em `docker
compose up` nem em code review superficial — só ao notar, dias depois, que o
banco "esqueceu" tudo. Este teste existe para que remover ou alterar a linha
`name:` quebre a suíte imediatamente, em vez de quebrar em produção.
"""

from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
EXPECTED_PROJECT_NAME = "gs-stationmanager"


def _load_compose(filename: str) -> dict:
    path = REPO_ROOT / filename
    with open(path) as f:
        return yaml.safe_load(f)


def test_docker_compose_pins_project_name():
    compose = _load_compose("docker-compose.yml")
    assert compose.get("name") == EXPECTED_PROJECT_NAME, (
        "docker-compose.yml perdeu (ou mudou) a linha 'name:'. Isso muda o "
        "prefixo dos volumes nomeados e pode fazer um clone em outra pasta "
        "montar volumes vazios silenciosamente — ver o comentário no topo do "
        "arquivo antes de alterar isto."
    )


def test_docker_compose_named_volumes_are_the_expected_ones():
    # Trava também os nomes dos dois volumes que dependem do prefixo acima,
    # para que uma renomeação de volume não passe despercebida junto de uma
    # mudança (ou remoção) do 'name:'.
    compose = _load_compose("docker-compose.yml")
    assert set(compose.get("volumes", {}).keys()) == {"postgres_data", "tracking_data"}
