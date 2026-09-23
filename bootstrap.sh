#!/usr/bin/env bash
# Clona (ou atualiza) os repositórios da estação em repos/.
#
# Tradução do bootstrap.ps1, para Linux e CI. O PowerShell é o caminho
# primário no Windows, que é onde a estação é desenvolvida hoje.
#
#   ./bootstrap.sh           clona/atualiza
#   ./bootstrap.sh --dev     e instala em modo editável no venv ativo
#   ./bootstrap.sh --check   só confere, não clona

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$ROOT/repos.txt"
REPOS_DIR="$ROOT/repos"

DEV=0
CHECK=0
for arg in "$@"; do
  case "$arg" in
    --dev)   DEV=1 ;;
    --check) CHECK=1 ;;
    *) echo "argumento desconhecido: $arg" >&2; exit 2 ;;
  esac
done

[ -f "$MANIFEST" ] || { echo "repos.txt não encontrado em $ROOT" >&2; exit 1; }

# Lê o manifesto ignorando vazios e comentários.
entries=()
while read -r name url ref _rest; do
  [ -z "${name:-}" ] && continue
  case "$name" in \#*) continue ;; esac
  [ -z "${ref:-}" ] && { echo "linha ignorada (esperava 'nome url ref'): $name" >&2; continue; }
  entries+=("$name|$url|$ref")
done < "$MANIFEST"

blessed_tracking=""
for entry in "${entries[@]}"; do
  IFS='|' read -r name _url ref <<< "$entry"
  [ "$name" = "spacelab-tracking" ] && blessed_tracking="$ref"
done

tracking_pin() {
  local pyproject="$1/pyproject.toml"
  [ -f "$pyproject" ] || return 1
  sed -nE 's/.*spacelab-tracking[[:space:]]*@[[:space:]]*git\+[^@]+@([^"'"'"'[:space:]]+).*/\1/p' \
    "$pyproject" | head -1
}

check_pins() {
  local problems=0
  for entry in "${entries[@]}"; do
    IFS='|' read -r name _url _ref <<< "$entry"
    local path="$REPOS_DIR/$name"
    [ -d "$path" ] || continue
    local pin
    pin="$(tracking_pin "$path" || true)"
    [ -z "$pin" ] && continue
    if [ "$pin" != "$blessed_tracking" ]; then
      echo "AVISO: $name pina spacelab-tracking@$pin, mas repos.txt diz $blessed_tracking" >&2
      problems=$((problems + 1))
    else
      echo "  ok  $name -> spacelab-tracking@$pin"
    fi
  done
  if [ "$problems" -gt 0 ]; then
    echo "AVISO: tags divergentes. O payload de track_satellite no ZMQ 5580 é" >&2
    echo "       OrbitalData.to_json(); formatos incompatíveis falham no meio de" >&2
    echo "       uma passagem, não no boot." >&2
  fi
  return 0
}

if [ "$CHECK" = 1 ]; then
  echo "Conferindo repos/..."
  missing=0
  for entry in "${entries[@]}"; do
    IFS='|' read -r name _url _ref <<< "$entry"
    if [ -d "$REPOS_DIR/$name" ]; then
      echo "  ok  repos/$name"
    else
      echo "  FALTA  repos/$name"
      missing=$((missing + 1))
    fi
  done
  echo
  echo "Conferindo as tags da spacelab-tracking..."
  check_pins
  if [ "$missing" -gt 0 ]; then
    echo >&2
    echo "$missing repositório(s) faltando. Rode ./bootstrap.sh sem --check." >&2
    exit 1
  fi
  echo
  echo "Tudo certo."
  exit 0
fi

mkdir -p "$REPOS_DIR"

for entry in "${entries[@]}"; do
  IFS='|' read -r name url ref <<< "$entry"
  path="$REPOS_DIR/$name"
  echo
  echo "=== $name ==="

  if [ ! -d "$path" ]; then
    echo "  clonando $url"
    # advice.detachedHead=false: a spacelab-tracking é clonada numa tag, e o
    # aviso de 'detached HEAD' do git aí é esperado, não um problema.
    if ! git -c advice.detachedHead=false clone --quiet --branch "$ref" "$url" "$path"; then
      # `--branch` aceita branch e TAG, mas não SHA de commit. Nenhuma
      # entrada do repos.txt pina um SHA hoje, mas já pinou — e voltará
      # docs/rx-datapath.md), e sem este fallback o bootstrap morreria ali
      # com um erro do git que não explica nada.
      echo "  ref não é branch/tag; clonando e fazendo checkout de $ref"
      git clone --quiet "$url" "$path" || { echo "  ERRO: falha ao clonar $name" >&2; exit 1; }
      git -C "$path" -c advice.detachedHead=false checkout --quiet "$ref"         || { echo "  ERRO: falha no checkout de $ref em $name" >&2; exit 1; }
    fi
    continue
  fi

  echo "  já existe; buscando atualizações"
  git -C "$path" fetch --all --tags --quiet || echo "  AVISO: fetch falhou"

  # Nunca sobrescreve trabalho local sem pedir.
  if [ -n "$(git -C "$path" status --porcelain)" ]; then
    echo "  AVISO: árvore com alterações locais; não vou trocar de ref."
    continue
  fi

  current="$(git -C "$path" rev-parse --abbrev-ref HEAD)"
  if [ "$current" != "$ref" ]; then
    echo "  checkout $ref (estava em $current)"
    git -C "$path" checkout --quiet "$ref"
  else
    git -C "$path" pull --ff-only --quiet || echo "  AVISO: pull não foi fast-forward."
  fi
done

if [ "$DEV" = 1 ]; then
  echo
  echo "=== instalando em modo editável ==="
  # A ordem importa: a biblioteca primeiro, para que os serviços resolvam
  # contra a árvore de trabalho e não baixem a tag publicada do GitHub.
  for name in spacelab-tracking grs-station-manager grs-manager grs-tc-scheduler grs-iq-recorder grs-sdr-sim grs-demodulator; do
    path="$REPOS_DIR/$name"
    [ -d "$path" ] || { echo "  pulando $name (não clonado)"; continue; }
    echo "  pip install -e repos/$name"
    python -m pip install --quiet -e "$path" || echo "  AVISO: falhou em $name"
  done
  python -m pip install --quiet -e "$ROOT[dev]"
fi

echo
echo "=== tags da spacelab-tracking ==="
check_pins

echo
echo "Pronto. Agora: docker compose up -d --build"
