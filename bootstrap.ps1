<#
.SYNOPSIS
    Clona (ou atualiza) os repositórios da estação em repos/.

.DESCRIPTION
    Substitui os submódulos git. Lê repos.txt e deixa cada bloco da estação em
    repos/<nome>, que é o build context que o docker-compose.yml usa.

    Nunca faz merge automático: se a sua árvore de trabalho tem alterações, o
    script avisa e segue em frente em vez de sobrescrever o seu trabalho.

.PARAMETER Dev
    Além de clonar, instala cada repo em modo editável no venv ativo. É o que
    faz o teste e2e (tests/) rodar contra as suas árvores de trabalho em vez de
    contra as tags publicadas.

.PARAMETER Check
    Não clona nada: só confere que os repos estão presentes e que as tags da
    spacelab-tracking não divergem entre os serviços. Rode antes de um
    `docker compose up` para não descobrir o problema por um erro críptico de
    contexto do Docker.

.PARAMETER Lock
    Em vez de seguir as branches do repos.txt, põe cada repositório no commit
    exato gravado em repos.lock. É o que volta a estação inteira a uma versão
    congelada por tools\congelar.ps1:

        git checkout estacao-2026.11.0
        .\bootstrap.ps1 -Lock

    Os repositórios ficam em 'detached HEAD', o que é esperado. No fim, confere
    que TODOS estão no commit do lock, e sai com erro se algum não estiver (um
    repositório com alteração local não é tocado). Com -Check, só faz essa
    conferência. Para voltar ao desenvolvimento: git checkout <branch> aqui, e
    .\bootstrap.ps1 sem -Lock.

.EXAMPLE
    .\bootstrap.ps1
    .\bootstrap.ps1 -Dev
    .\bootstrap.ps1 -Check
    .\bootstrap.ps1 -Lock
    .\bootstrap.ps1 -Lock -Check
#>
[CmdletBinding()]
param(
    [switch]$Dev,
    [switch]$Check,
    [switch]$Lock
)

# "Continue", e não "Stop": no Windows PowerShell 5.1 o git escreve mensagens
# normais ("Cloning into...") no stderr, e com "Stop" isso vira um
# NativeCommandError fatal. O sucesso de cada comando do git é conferido pelo
# $LASTEXITCODE, que é o que de fato reflete o código de saída.
$ErrorActionPreference = "Continue"
$root = $PSScriptRoot
$manifest = Join-Path $root "repos.txt"
$lockFile = Join-Path $root "repos.lock"
$reposDir = Join-Path $root "repos"

if (-not (Test-Path $manifest)) {
    Write-Host "repos.txt não encontrado em $root" -ForegroundColor Red
    exit 1
}

# Lê um manifesto (o repos.txt, ou o repos.lock, que tem o mesmo formato):
# ignora linhas vazias e comentários.
function Read-Manifest {
    param([string]$File)
    $result = @()
    foreach ($line in Get-Content $File) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) { continue }
        $parts = $trimmed -split '\s+'
        if ($parts.Count -lt 3) {
            Write-Warning "Linha ignorada em $(Split-Path $File -Leaf) (esperava 'nome url ref'): $trimmed"
            continue
        }
        $result += [pscustomobject]@{ Name = $parts[0]; Url = $parts[1]; Ref = $parts[2] }
    }
    return $result
}

function Get-Short([string]$Sha) {
    if ($Sha.Length -gt 7) { return $Sha.Substring(0, 7) }
    return $Sha
}

$manifestEntries = @(Read-Manifest $manifest)
# A tag abençoada da spacelab-tracking vem SEMPRE do repos.txt, mesmo com
# -Lock: no lock ela vira um SHA, e os pyproject.toml pinam pela tag.
$blessedTracking = ($manifestEntries | Where-Object { $_.Name -eq "spacelab-tracking" }).Ref

if ($Lock) {
    if (-not (Test-Path $lockFile)) {
        Write-Host "repos.lock não existe em $root." -ForegroundColor Red
        Write-Host ("Este commit do grs-station nunca foi congelado. Faça checkout de uma versão " +
                    "(git tag -l) ou congele uma com tools\congelar.ps1.") -ForegroundColor Red
        exit 1
    }
    $entries = @(Read-Manifest $lockFile)
    $notSha = @($entries | Where-Object { $_.Ref -notmatch '^[0-9a-f]{40}$' })
    if ($notSha.Count -gt 0) {
        $notSha | ForEach-Object { Write-Host "repos.lock: $($_.Name) tem '$($_.Ref)', que não é um SHA completo." -ForegroundColor Red }
        exit 1
    }
    $stationAt = git -C $root describe --tags --always --dirty
    Write-Host "Modo -Lock: grs-station em $stationAt; cada repositório vai para o commit exato do repos.lock." -ForegroundColor Cyan
    if ($stationAt -like "*-dirty") {
        Write-Warning "O grs-station tem alterações locais: o compose que vai subir não é exatamente o da versão."
    }
    # Repositório que entrou no repos.txt depois do último congelamento não
    # tem SHA no lock. Avisa em vez de inventar um.
    foreach ($m in $manifestEntries) {
        if (-not ($entries | Where-Object { $_.Name -eq $m.Name })) {
            Write-Warning "$($m.Name) está no repos.txt mas não no repos.lock: entrou depois do último congelamento e fica como está."
        }
    }
} else {
    $entries = $manifestEntries
}

# Confere que cada repositório está no commit exato do lock. É a única
# garantia de que a estação inteira está na versão: o laço de checkout pula,
# de propósito, quem tem alteração local, e sem esta conferência o -Lock
# "terminaria bem" com a estação metade numa versão e metade noutra.
function Test-LockState {
    param([array]$Entries)
    $wrong = 0
    foreach ($entry in $Entries) {
        $path = Join-Path $reposDir $entry.Name
        if (-not (Test-Path $path)) {
            Write-Host "  FALTA      repos/$($entry.Name)" -ForegroundColor Red
            $wrong++
            continue
        }
        $head = git -C $path rev-parse HEAD
        if ($head -ne $entry.Ref) {
            Write-Host ("  DIFERENTE  {0,-26} está em {1}, o lock diz {2}" -f $entry.Name, (Get-Short $head), (Get-Short $entry.Ref)) -ForegroundColor Red
            $wrong++
        } elseif (git -C $path status --porcelain) {
            Write-Host ("  ALTERADO   {0,-26} no commit certo, mas com alterações locais" -f $entry.Name) -ForegroundColor Red
            $wrong++
        } else {
            Write-Host ("  ok  {0,-26} {1}" -f $entry.Name, (Get-Short $entry.Ref)) -ForegroundColor DarkGray
        }
    }
    return $wrong
}

function Get-TrackingPin {
    param([string]$RepoPath)
    $pyproject = Join-Path $RepoPath "pyproject.toml"
    if (-not (Test-Path $pyproject)) { return $null }
    $match = Select-String -Path $pyproject -Pattern 'spacelab-tracking\s*@\s*git\+[^@]+@([^\"''\s]+)'
    if ($null -eq $match) { return $null }
    return $match.Matches[0].Groups[1].Value
}

function Test-TrackingPins {
    param([array]$Entries, [string]$Blessed)

    $problems = 0
    foreach ($entry in $Entries) {
        $path = Join-Path $reposDir $entry.Name
        if (-not (Test-Path $path)) { continue }
        $pin = Get-TrackingPin -RepoPath $path
        if ($null -eq $pin) { continue }
        if ($pin -ne $Blessed) {
            Write-Warning "$($entry.Name) pina spacelab-tracking@$pin, mas repos.txt diz $Blessed."
            $problems++
        } else {
            Write-Host "  ok  $($entry.Name) -> spacelab-tracking@$pin" -ForegroundColor DarkGray
        }
    }
    if ($problems -gt 0) {
        Write-Warning ("Tags divergentes da spacelab-tracking. O payload de track_satellite " +
                       "no ZMQ 5580 e OrbitalData.to_json(): formatos incompativeis falham " +
                       "no meio de uma passagem, nao no boot.")
    }
    return $problems
}

if ($Check) {
    Write-Host "Conferindo repos/..." -ForegroundColor Cyan
    $missing = 0
    foreach ($entry in $entries) {
        $path = Join-Path $reposDir $entry.Name
        if (Test-Path $path) {
            Write-Host "  ok  repos/$($entry.Name)" -ForegroundColor DarkGray
        } else {
            Write-Host "  FALTA  repos/$($entry.Name)" -ForegroundColor Red
            $missing++
        }
    }
    Write-Host "`nConferindo as tags da spacelab-tracking..." -ForegroundColor Cyan
    $pinProblems = Test-TrackingPins -Entries $entries -Blessed $blessedTracking

    $lockWrong = 0
    if ($Lock) {
        Write-Host "`nConferindo os commits do repos.lock..." -ForegroundColor Cyan
        $lockWrong = Test-LockState -Entries $entries
    }

    $fix = if ($Lock) { ".\bootstrap.ps1 -Lock" } else { ".\bootstrap.ps1 sem -Check" }
    if ($missing -gt 0) {
        Write-Host "`n$missing repositório(s) faltando. Rode $fix." -ForegroundColor Red
    }
    if ($lockWrong -gt 0) {
        # A contagem inclui os que faltam: o Test-LockState também os lista.
        Write-Host "`n$lockWrong repositório(s) fora da versão $stationAt. Rode $fix." -ForegroundColor Red
    }
    if ($missing -gt 0 -or $lockWrong -gt 0) { exit 1 }
    if ($pinProblems -eq 0) { Write-Host "`nTudo certo." -ForegroundColor Green }
    return
}

New-Item -ItemType Directory -Force -Path $reposDir | Out-Null

foreach ($entry in $entries) {
    $path = Join-Path $reposDir $entry.Name
    Write-Host "`n=== $($entry.Name) ===" -ForegroundColor Cyan

    if (-not (Test-Path $path)) {
        Write-Host "  clonando $($entry.Url)"
        # `--branch` aceita branch e TAG, mas não SHA de commit, que é o que o
        # repos.lock sempre tem (e o repos.txt pode voltar a ter, no dia em que
        # algum bloco precisar de um ref sem nome). Com SHA, vai direto ao
        # clone + checkout; com nome que não resolve, cai nele também, em vez
        # de morrer com um erro do git que não explica nada.
        $isSha = $entry.Ref -match '^[0-9a-f]{40}$'
        if (-not $isSha) {
            # advice.detachedHead=false: a spacelab-tracking é clonada numa tag, e o
            # aviso de 'detached HEAD' do git aí é esperado, não um problema.
            git -c advice.detachedHead=false clone --quiet --branch $entry.Ref $entry.Url $path
        }
        if ($isSha -or $LASTEXITCODE -ne 0) {
            if (-not $isSha) { Write-Host "  ref não é branch/tag; clonando e fazendo checkout de $($entry.Ref)" }
            git clone --quiet $entry.Url $path
            if ($LASTEXITCODE -ne 0) { Write-Host "  Falha ao clonar $($entry.Name)" -ForegroundColor Red; exit 1 }
            git -C $path -c advice.detachedHead=false checkout --quiet $entry.Ref
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  Falha no checkout de $($entry.Ref) em $($entry.Name)" -ForegroundColor Red
                exit 1
            }
        }
        continue
    }

    # Com -Lock, repositório já no commit certo e limpo não precisa nem de fetch.
    if ($Lock -and ((git -C $path rev-parse HEAD) -eq $entry.Ref) -and -not (git -C $path status --porcelain)) {
        Write-Host "  ja esta em $(Get-Short $entry.Ref)"
        continue
    }

    Write-Host "  ja existe; buscando atualizacoes"
    git -C $path fetch --all --tags --quiet
    if ($LASTEXITCODE -ne 0) { Write-Warning "  fetch falhou em $($entry.Name)" }

    # Nunca sobrescreve trabalho local sem pedir.
    $dirty = git -C $path status --porcelain
    if ($dirty) {
        Write-Warning "  arvore com alteracoes locais; nao vou trocar de ref. Deixando como esta."
        continue
    }

    $current = git -C $path rev-parse --abbrev-ref HEAD
    if ($Lock) {
        Write-Host "  checkout $(Get-Short $entry.Ref) (estava em $current, $(Get-Short (git -C $path rev-parse HEAD)))"
        git -C $path -c advice.detachedHead=false checkout --quiet $entry.Ref
        if ($LASTEXITCODE -ne 0) { Write-Warning "  checkout de $(Get-Short $entry.Ref) falhou em $($entry.Name)" }
        continue
    }
    if ($current -ne $entry.Ref) {
        Write-Host "  checkout $($entry.Ref) (estava em $current)"
        git -C $path checkout --quiet $entry.Ref
        if ($LASTEXITCODE -ne 0) { Write-Warning "  checkout de $($entry.Ref) falhou em $($entry.Name)" }
    }
    if ($current -eq $entry.Ref) {
        git -C $path pull --ff-only --quiet
        if ($LASTEXITCODE -ne 0) { Write-Warning "  pull não foi fast-forward; deixando como está." }
    }
}

if ($Lock) {
    Write-Host "`n=== conferindo a versão ===" -ForegroundColor Cyan
    $lockWrong = Test-LockState -Entries $entries
    if ($lockWrong -gt 0) {
        Write-Host "`n$lockWrong repositório(s) fora do commit do repos.lock: a estação NÃO está em $stationAt." -ForegroundColor Red
        Write-Host "Resolva os itens acima (alteração local: commit ou stash) e rode .\bootstrap.ps1 -Lock de novo." -ForegroundColor Red
        exit 1
    }
    Write-Host "`nTodos os $($entries.Count) repositórios no commit do repos.lock ($stationAt)." -ForegroundColor Green
}

if ($Dev) {
    Write-Host "`n=== instalando em modo editavel ===" -ForegroundColor Cyan
    # A ordem importa: a biblioteca primeiro, para que os servicos resolvam
    # contra a arvore de trabalho e nao baixem a tag publicada do GitHub.
    foreach ($name in @("spacelab-tracking", "grs-station-manager", "grs-manager", "grs-tc-scheduler",
                        "grs-iq-recorder", "grs-sdr-sim", "grs-fft", "grs-spectrum-monitor", "grs-demodulator",
                        "grs-telemetry-decoder", "grs-uplink")) {
        $path = Join-Path $reposDir $name
        if (-not (Test-Path $path)) { Write-Warning "  pulando $name (nao clonado)"; continue }
        Write-Host "  pip install -e repos/$name"
        python -m pip install --quiet -e $path
        if ($LASTEXITCODE -ne 0) { Write-Warning "  falhou em $name" }
    }
    # O sintetizador e um script, sem pyproject (assim veio do upstream): so as
    # dependencias. Os testes dele acham o modulo pelo proprio caminho.
    $synth = Join-Path $reposDir "grs-frequency-synthesizer\requirements.txt"
    if (Test-Path $synth) {
        Write-Host "  pip install -r repos/grs-frequency-synthesizer/requirements.txt"
        python -m pip install --quiet -r $synth
        if ($LASTEXITCODE -ne 0) { Write-Warning "  falhou em grs-frequency-synthesizer" }
    }
    # Confere o código de saída: este install é o que traz o pytest, e sem ele
    # o test-all.ps1 reporta TODOS os repositórios como falhos sem dizer por quê.
    Write-Host "  pip install -e .[dev]"
    python -m pip install --quiet -e "$root[dev]"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning ("Falhou instalar o proprio orquestrador em modo editavel. " +
                       "Sem isso nao ha pytest, e o test-all.ps1 vai falhar em tudo. " +
                       "Rode sem --quiet para ver o erro: python -m pip install -e `"$root[dev]`"")
    }
}

Write-Host "`n=== tags da spacelab-tracking ===" -ForegroundColor Cyan
Test-TrackingPins -Entries $entries -Blessed $blessedTracking | Out-Null

Write-Host "`nPronto. Agora: docker compose up -d --build" -ForegroundColor Green
if ($Lock) {
    Write-Host "Para voltar ao desenvolvimento: git checkout <branch> aqui, e .\bootstrap.ps1 sem -Lock."
}
