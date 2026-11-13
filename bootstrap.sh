#!/usr/bin/env bash
# Clona (ou atualiza) os repositórios da estação em repos/.
#
# Tradução do bootstrap.ps1, para Linux e CI. O PowerShell é o caminho
# primário no Windows, que é onde a estação é desenvolvida hoje.
#
#   ./bootstrap.sh                 clona/atualiza, seguindo as branches do repos.txt
#   ./bootstrap.sh --dev           e instala em modo editável no venv ativo
#   ./bootstrap.sh --check         só confere, não clona
#   ./bootstrap.sh --lock          põe cada repo no commit exato do repos.lock
#   ./bootstrap.sh --lock --check  só confere se a estação está na versão do lock
#
# Voltar a estação inteira a uma versão congelada (tools/congelar.ps1):
#
#   git checkout estacao-2026.11.0 && ./bootstrap.sh --lock
#
# Os repositórios ficam em 'detached HEAD', o que é esperado. Para voltar ao
# desenvolvimento: git checkout <branch> aqui, e ./bootstrap.sh sem --lock.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$ROOT/repos.txt"
LOCKFILE="$ROOT/repos.lock"
REPOS_DIR="$ROOT/repos"

DEV=0
CHECK=0
LOCK=0
for arg in "$@"; do
  case "$arg" in
    --dev)   DEV=1 ;;
    --check) CHECK=1 ;;
    --lock)  LOCK=1 ;;
    *) echo "argumento desconhecido: $arg" >&2; exit 2 ;;
  esac
done

[ -f "$MANIFEST" ] || { echo "repos.txt não encontrado em $ROOT" >&2; exit 1; }

# Lê um manifesto (o repos.txt, ou o repos.lock, que tem o mesmo formato)
# ignorando vazios e comentários, e emite "nome|url|ref", um por linha. O `\r`
# sai porque num clone Windows o text=auto deixa os dois arquivos com CRLF.
read_manifest() {
  local name url ref _rest
  while read -r name url ref _rest; do
    name="${name%$'\r'}"; url="${url%$'\r'}"; ref="${ref%$'\r'}"
    [ -z "${name:-}" ] && continue
    case "$name" in \#*) continue ;; esac
    [ -z "${ref:-}" ] && { echo "linha ignorada em $(basename "$1") (esperava 'nome url ref'): $name" >&2; continue; }
    echo "$name|$url|$ref"
  done < "$1"
}

is_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
short() { printf '%s' "${1:0:7}"; }

manifest_entries=()
while IFS= read -r e; do manifest_entries+=("$e"); done < <(read_manifest "$MANIFEST")

# A tag abençoada da spacelab-tracking vem SEMPRE do repos.txt, mesmo com
# --lock: no lock ela vira um SHA, e os pyproject.toml pinam pela tag.
blessed_tracking=""
for entry in "${manifest_entries[@]}"; do
  IFS='|' read -r name _url ref <<< "$entry"
  [ "$name" = "spacelab-tracking" ] && blessed_tracking="$ref"
done

station_at=""
if [ "$LOCK" = 1 ]; then
  if [ ! -f "$LOCKFILE" ]; then
    echo "repos.lock não existe em $ROOT." >&2
    echo "Este commit do grs-station nunca foi congelado. Faça checkout de uma versão" >&2
    echo "(git tag -l) ou congele uma com tools/congelar.ps1." >&2
    exit 1
  fi
  entries=()
  while IFS= read -r e; do entries+=("$e"); done < <(read_manifest "$LOCKFILE")
  for entry in "${entries[@]}"; do
    IFS='|' read -r name _url ref <<< "$entry"
    is_sha "$ref" || { echo "repos.lock: $name tem '$ref', que não é um SHA completo." >&2; exit 1; }
  done
  station_at="$(git -C "$ROOT" describe --tags --always --dirty)"
  echo "Modo --lock: grs-station em $station_at; cada repositório vai para o commit exato do repos.lock."
  case "$station_at" in
    *-dirty) echo "AVISO: o grs-station tem alterações locais: o compose que vai subir não é exatamente o da versão." >&2 ;;
  esac
  # Repositório que entrou no repos.txt depois do último congelamento não tem
  # SHA no lock. Avisa em vez de inventar um.
  for m in "${manifest_entries[@]}"; do
    found=0
    for entry in "${entries[@]}"; do [ "${entry%%|*}" = "${m%%|*}" ] && found=1; done
    [ "$found" = 1 ] || echo "AVISO: ${m%%|*} está no repos.txt mas não no repos.lock: entrou depois do último congelamento e fica como está." >&2
  done
else
  entries=("${manifest_entries[@]}")
fi

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

# Confere que cada repositório está no commit exato do lock e deixa a contagem
# em lock_wrong. É a única garantia de que a estação inteira está na versão: o
# laço de checkout pula, de propósito, quem tem alteração local, e sem esta
# conferência o --lock "terminaria bem" com a estação metade numa versão e
# metade noutra.
lock_wrong=0
check_lock() {
  local entry name _url ref path head
  lock_wrong=0
  for entry in "${entries[@]}"; do
    IFS='|' read -r name _url ref <<< "$entry"
    path="$REPOS_DIR/$name"
    if [ ! -d "$path" ]; then
      echo "  FALTA      repos/$name" >&2
      lock_wrong=$((lock_wrong + 1))
      continue
    fi
    head="$(git -C "$path" rev-parse HEAD 2>/dev/null || echo '(nenhum)')"
    if [ "$head" != "$ref" ]; then
      printf '  DIFERENTE  %-26s está em %s, o lock diz %s\n' "$name" "$(short "$head")" "$(short "$ref")" >&2
      lock_wrong=$((lock_wrong + 1))
    elif [ -n "$(git -C "$path" status --porcelain)" ]; then
      printf '  ALTERADO   %-26s no commit certo, mas com alterações locais\n' "$name" >&2
      lock_wrong=$((lock_wrong + 1))
    else
      printf '  ok  %-26s %s\n' "$name" "$(short "$ref")"
    fi
  done
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
  if [ "$LOCK" = 1 ]; then
    echo
    echo "Conferindo os commits do repos.lock..."
    check_lock
  fi
  if [ "$LOCK" = 1 ]; then fix="./bootstrap.sh --lock"; else fix="./bootstrap.sh sem --check"; fi
  if [ "$missing" -gt 0 ]; then
    echo >&2
    echo "$missing repositório(s) faltando. Rode $fix." >&2
  fi
  if [ "$lock_wrong" -gt 0 ]; then
    # A contagem inclui os que faltam: o check_lock também os lista.
    echo >&2
    echo "$lock_wrong repositório(s) fora da versão $station_at. Rode $fix." >&2
  fi
  if [ "$missing" -gt 0 ] || [ "$lock_wrong" -gt 0 ]; then exit 1; fi
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
    # `--branch` aceita branch e TAG, mas não SHA de commit, que é o que o
    # repos.lock sempre tem (e o repos.txt pode voltar a ter, no dia em que
    # algum bloco precisar de um ref sem nome). Com SHA, vai direto ao clone +
    # checkout; com nome que não resolve, cai nele também, em vez de morrer
    # com um erro do git que não explica nada.
    # advice.detachedHead=false: a spacelab-tracking é clonada numa tag, e o
    # aviso de 'detached HEAD' do git aí é esperado, não um problema.
    if is_sha "$ref" || ! git -c advice.detachedHead=false clone --quiet --branch "$ref" "$url" "$path"; then
      is_sha "$ref" || echo "  ref não é branch/tag; clonando e fazendo checkout de $ref"
      git clone --quiet "$url" "$path" || { echo "  ERRO: falha ao clonar $name" >&2; exit 1; }
      git -C "$path" -c advice.detachedHead=false checkout --quiet "$ref" \
        || { echo "  ERRO: falha no checkout de $ref em $name" >&2; exit 1; }
    fi
    continue
  fi

  # Com --lock, repositório já no commit certo e limpo não precisa nem de fetch.
  if [ "$LOCK" = 1 ] && [ "$(git -C "$path" rev-parse HEAD)" = "$ref" ] \
     && [ -z "$(git -C "$path" status --porcelain)" ]; then
    echo "  já está em $(short "$ref")"
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
  if [ "$LOCK" = 1 ]; then
    echo "  checkout $(short "$ref") (estava em $current, $(short "$(git -C "$path" rev-parse HEAD)"))"
    git -C "$path" -c advice.detachedHead=false checkout --quiet "$ref" \
      || echo "  AVISO: checkout de $(short "$ref") falhou em $name" >&2
    continue
  fi
  if [ "$current" != "$ref" ]; then
    echo "  checkout $ref (estava em $current)"
    git -C "$path" checkout --quiet "$ref"
  else
    git -C "$path" pull --ff-only --quiet || echo "  AVISO: pull não foi fast-forward."
  fi
done

if [ "$LOCK" = 1 ]; then
  echo
  echo "=== conferindo a versão ==="
  check_lock
  if [ "$lock_wrong" -gt 0 ]; then
    echo >&2
    echo "$lock_wrong repositório(s) fora do commit do repos.lock: a estação NÃO está em $station_at." >&2
    echo "Resolva os itens acima (alteração local: commit ou stash) e rode ./bootstrap.sh --lock de novo." >&2
    exit 1
  fi
  echo
  echo "Todos os ${#entries[@]} repositórios no commit do repos.lock ($station_at)."
fi

if [ "$DEV" = 1 ]; then
  echo
  echo "=== instalando em modo editável ==="
  # A ordem importa: a biblioteca primeiro, para que os serviços resolvam
  # contra a árvore de trabalho e não baixem a tag publicada do GitHub.
  for name in spacelab-tracking grs-station-manager grs-manager grs-tc-scheduler grs-iq-recorder grs-sdr-sim grs-demodulator grs-telemetry-decoder grs-uplink; do
    path="$REPOS_DIR/$name"
    [ -d "$path" ] || { echo "  pulando $name (não clonado)"; continue; }
    echo "  pip install -e repos/$name"
    python -m pip install --quiet -e "$path" || echo "  AVISO: falhou em $name"
  done
  # Confere o codigo de saida: este install e o que traz o pytest, e sem ele o
  # test-all reporta TODOS os repositorios como falhos sem dizer por que.
  echo "  pip install -e .[dev]"
  python -m pip install --quiet -e "$ROOT[dev]" || echo     "AVISO: falhou instalar o orquestrador em modo editavel. Sem isso nao ha pytest." >&2
fi

echo
echo "=== tags da spacelab-tracking ==="
check_pins

echo
echo "Pronto. Agora: docker compose up -d --build"
if [ "$LOCK" = 1 ]; then
  echo "Para voltar ao desenvolvimento: git checkout <branch> aqui, e ./bootstrap.sh sem --lock."
fi
