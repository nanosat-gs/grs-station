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

.EXAMPLE
    .\bootstrap.ps1
    .\bootstrap.ps1 -Dev
    .\bootstrap.ps1 -Check
#>
[CmdletBinding()]
param(
    [switch]$Dev,
    [switch]$Check
)

# "Continue", e não "Stop": no Windows PowerShell 5.1 o git escreve mensagens
# normais ("Cloning into...") no stderr, e com "Stop" isso vira um
# NativeCommandError fatal. O sucesso de cada comando do git é conferido pelo
# $LASTEXITCODE, que é o que de fato reflete o código de saída.
$ErrorActionPreference = "Continue"
$root = $PSScriptRoot
$manifest = Join-Path $root "repos.txt"
$reposDir = Join-Path $root "repos"

if (-not (Test-Path $manifest)) {
    Write-Host "repos.txt não encontrado em $root" -ForegroundColor Red
    exit 1
}

# Lê o manifesto: ignora linhas vazias e comentários.
$entries = @()
foreach ($line in Get-Content $manifest) {
    $trimmed = $line.Trim()
    if ($trimmed -eq "" -or $trimmed.StartsWith("#")) { continue }
    $parts = $trimmed -split '\s+'
    if ($parts.Count -lt 3) {
        Write-Warning "Linha ignorada (esperava 'nome url ref'): $trimmed"
        continue
    }
    $entries += [pscustomobject]@{ Name = $parts[0]; Url = $parts[1]; Ref = $parts[2] }
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
    param([array]$Entries)

    $blessed = ($Entries | Where-Object { $_.Name -eq "spacelab-tracking" }).Ref
    $problems = 0
    foreach ($entry in $Entries) {
        $path = Join-Path $reposDir $entry.Name
        if (-not (Test-Path $path)) { continue }
        $pin = Get-TrackingPin -RepoPath $path
        if ($null -eq $pin) { continue }
        if ($pin -ne $blessed) {
            Write-Warning "$($entry.Name) pina spacelab-tracking@$pin, mas repos.txt diz $blessed."
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
    $pinProblems = Test-TrackingPins -Entries $entries

    if ($missing -gt 0) {
        Write-Host "$missing repositório(s) faltando. Rode .\bootstrap.ps1 sem -Check." -ForegroundColor Red
        exit 1
    }
    if ($pinProblems -eq 0) { Write-Host "`nTudo certo." -ForegroundColor Green }
    return
}

New-Item -ItemType Directory -Force -Path $reposDir | Out-Null

foreach ($entry in $entries) {
    $path = Join-Path $reposDir $entry.Name
    Write-Host "`n=== $($entry.Name) ===" -ForegroundColor Cyan

    if (-not (Test-Path $path)) {
        Write-Host "  clonando $($entry.Url)"
        # advice.detachedHead=false: a spacelab-tracking é clonada numa tag, e o
        # aviso de 'detached HEAD' do git aí é esperado, não um problema.
        git -c advice.detachedHead=false clone --quiet --branch $entry.Ref $entry.Url $path
        if ($LASTEXITCODE -ne 0) {
            # `--branch` aceita branch e TAG, mas não SHA de commit. Nenhuma
            # entrada do repos.txt pina um SHA hoje, mas já pinou — e voltará
            # a pinar no dia em que algum bloco precisar de um ref sem nome.
            # Sem este fallback, o bootstrap morre com um erro do git que
      # não explica nada.
            Write-Host "  ref não é branch/tag; clonando e fazendo checkout de $($entry.Ref)"
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

if ($Dev) {
    Write-Host "`n=== instalando em modo editavel ===" -ForegroundColor Cyan
    # A ordem importa: a biblioteca primeiro, para que os servicos resolvam
    # contra a arvore de trabalho e nao baixem a tag publicada do GitHub.
    foreach ($name in @("spacelab-tracking", "grs-station-manager", "grs-manager", "grs-tc-scheduler", "grs-iq-recorder")) {
        $path = Join-Path $reposDir $name
        if (-not (Test-Path $path)) { Write-Warning "  pulando $name (nao clonado)"; continue }
        Write-Host "  pip install -e repos/$name"
        python -m pip install --quiet -e $path
        if ($LASTEXITCODE -ne 0) { Write-Warning "  falhou em $name" }
    }
    python -m pip install --quiet -e "$root[dev]"
}

Write-Host "`n=== tags da spacelab-tracking ===" -ForegroundColor Cyan
Test-TrackingPins -Entries $entries | Out-Null

Write-Host "`nPronto. Agora: docker compose up -d --build" -ForegroundColor Green
