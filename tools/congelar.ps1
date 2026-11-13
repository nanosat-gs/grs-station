<#
.SYNOPSIS
    Congela a estação inteira numa versão: o commit exato de cada repositório
    vai para repos.lock, e o grs-station ganha uma tag com o nome da versão.

.DESCRIPTION
    A estação é feita de vários repositórios, e o repos.txt aponta branches,
    que andam. Por isso voltar só o grs-station para um commit antigo não volta
    o resto: o bootstrap baixaria a ponta atual de cada branch. O repos.lock
    fecha essa lacuna. Ele tem o mesmo formato do repos.txt, com o SHA de cada
    repositório no lugar da branch, e é commitado aqui. A tag desse commit é a
    versão da estação inteira. Para voltar a ela:

        git checkout estacao-2026.11.0
        .\bootstrap.ps1 -Lock
        docker compose up -d --build

    Antes de gravar qualquer coisa, o script confere tudo e RECUSA se algum
    repositório:
      - não está em repos/;
      - tem alteração não commitada (o que roda não seria o que foi gravado);
      - está num commit que não existe em nenhuma branch do origin (a versão
        só poderia ser restaurada nesta máquina);
      - tem o origin apontando para outro lugar que não a URL do repos.txt
        (o bootstrap clonaria de um lugar onde o commit talvez não exista).
    Recusa também se o próprio grs-station tem alteração não commitada (a tag
    apontaria para um compose diferente do que roda) ou está fora de uma
    branch.

    Não muda a branch de nenhum repositório: grava o que está em repos/, do
    jeito que está.

.PARAMETER Versao
    Nome da versão, que vira a tag. Sugestão: estacao-AAAA.MM.N, por exemplo
    estacao-2026.11.0.

.PARAMETER Publicar
    Envia a tag ao GitHub no fim. A tag leva junto o commit do repos.lock, então
    a versão fica restaurável de qualquer máquina mesmo que a branch atual ainda
    não tenha sido enviada.

.PARAMETER DryRun
    Só confere e mostra o repos.lock que seria gravado. Não escreve, não
    commita e não cria tag. (Faz `git fetch` em cada repositório: é assim que
    confere o que está no GitHub.)

.EXAMPLE
    .\tools\congelar.ps1 -Versao estacao-2026.11.0 -DryRun
    .\tools\congelar.ps1 -Versao estacao-2026.11.0
    .\tools\congelar.ps1 -Versao estacao-2026.11.0 -Publicar
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Versao,
    [switch]$Publicar,
    [switch]$DryRun
)

# "Continue" pelo mesmo motivo do bootstrap.ps1: no PowerShell 5.1 o git
# escreve mensagens normais no stderr. O sucesso é conferido pelo $LASTEXITCODE.
$ErrorActionPreference = "Continue"
$root = Split-Path $PSScriptRoot -Parent
$manifest = Join-Path $root "repos.txt"
$lockFile = Join-Path $root "repos.lock"
$reposDir = Join-Path $root "repos"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Get-Short([string]$Sha) {
    if ($Sha.Length -gt 7) { return $Sha.Substring(0, 7) }
    return $Sha
}

# Compara URLs de remote sem se importar com a forma: https ou ssh, com ou sem
# usuário, com ou sem .git no fim.
function Get-UrlKey([string]$Url) {
    $u = $Url.Trim()
    $u = $u -replace '^git@([^:]+):', '$1/'
    $u = $u -replace '^[a-z+]+://([^@/]+@)?', ''
    $u = $u.TrimEnd('/') -replace '\.git$', ''
    return $u.ToLowerInvariant()
}

if (-not (Test-Path $manifest)) {
    Write-Host "repos.txt não encontrado em $root" -ForegroundColor Red
    exit 1
}

$entries = @()
foreach ($line in Get-Content $manifest) {
    $trimmed = $line.Trim()
    if ($trimmed -eq "" -or $trimmed.StartsWith("#")) { continue }
    $parts = $trimmed -split '\s+'
    if ($parts.Count -lt 3) { continue }
    $entries += [pscustomobject]@{ Name = $parts[0]; Url = $parts[1]; Ref = $parts[2] }
}

$problems = 0
$rows = @()

# --- 1. Cada repositório ------------------------------------------------------
Write-Host "`n=== 1. Os $($entries.Count) repositórios do repos.txt ===" -ForegroundColor Cyan
foreach ($e in $entries) {
    $path = Join-Path $reposDir $e.Name
    if (-not (Test-Path (Join-Path $path ".git"))) {
        Write-Host ("  FALTA  {0}: não está em repos/. Rode .\bootstrap.ps1." -f $e.Name) -ForegroundColor Red
        $problems++
        continue
    }

    $sha = git -C $path rev-parse HEAD
    $branch = git -C $path symbolic-ref --short -q HEAD
    if (-not $branch) { $branch = "(detached)" }
    $mine = @()

    if (git -C $path status --porcelain) {
        $mine += "tem alterações não commitadas (commit ou stash antes)"
    }

    $origin = git -C $path remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $origin) {
        $mine += "não tem remote 'origin'"
    } elseif ((Get-UrlKey $origin) -ne (Get-UrlKey $e.Url)) {
        $mine += "o origin aponta para $origin, mas o repos.txt diz $($e.Url)"
    } else {
        # Fetch antes de conferir: a referência remota daqui pode estar velha,
        # e um force-push lá pode ter tirado o commit de todas as branches.
        git -C $path fetch origin --prune --quiet
        if ($LASTEXITCODE -ne 0) {
            $mine += "o fetch do origin falhou; sem ele não dá para saber se o commit está no GitHub"
        } else {
            $onRemote = @(git -C $path for-each-ref --contains $sha --format='%(refname:short)' refs/remotes/origin)
            if ($onRemote.Count -eq 0) {
                $mine += "o commit $(Get-Short $sha) não está em nenhuma branch do origin (falta git push)"
            }
        }
    }

    $rows += [pscustomobject]@{ Name = $e.Name; Url = $e.Url; Sha = $sha; Branch = $branch }
    # Estar numa branch diferente da do repos.txt não impede: o lock grava o
    # que roda. Mas fica à vista, porque costuma ser trabalho em andamento.
    $note = ""
    if ($branch -ne $e.Ref) { $note = "  (repos.txt diz $($e.Ref))" }

    if ($mine.Count -eq 0) {
        Write-Host ("  ok   {0,-26} {1}  {2}{3}" -f $e.Name, (Get-Short $sha), $branch, $note) -ForegroundColor DarkGray
    } else {
        Write-Host ("  NÃO  {0,-26} {1}  {2}{3}" -f $e.Name, (Get-Short $sha), $branch, $note) -ForegroundColor Red
        foreach ($m in $mine) { Write-Host "         $m" -ForegroundColor Red }
        $problems += $mine.Count
    }
}

# --- 2. O próprio grs-station -------------------------------------------------
Write-Host "`n=== 2. O grs-station ===" -ForegroundColor Cyan
$stationBranch = git -C $root symbolic-ref --short -q HEAD
if (-not $stationBranch) {
    Write-Host "  está fora de uma branch (detached HEAD): volte para uma branch antes de congelar" -ForegroundColor Red
    $problems++
}
# O repos.lock é o único arquivo que pode estar alterado: é o que este script escreve.
$stationDirty = @(git -C $root status --porcelain | Where-Object { $_ -notmatch '^.. repos\.lock$' })
if ($stationDirty.Count -gt 0) {
    Write-Host "  tem alterações não commitadas; a tag apontaria para um compose diferente do que roda:" -ForegroundColor Red
    foreach ($d in $stationDirty) { Write-Host "         $d" -ForegroundColor Red }
    $problems++
}
git check-ref-format "refs/tags/$Versao"
if ($LASTEXITCODE -ne 0) {
    Write-Host "  '$Versao' não é um nome de tag válido" -ForegroundColor Red
    $problems++
} else {
    git -C $root rev-parse -q --verify "refs/tags/$Versao" | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  a tag $Versao já existe aqui (git tag -l lista as versões)" -ForegroundColor Red
        $problems++
    }
    $remoteTag = git -C $root ls-remote --tags origin "refs/tags/$Versao"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  não consegui consultar as tags do origin" -ForegroundColor Red
        $problems++
    } elseif ($remoteTag) {
        Write-Host "  a tag $Versao já existe no GitHub" -ForegroundColor Red
        $problems++
    }
}
if ($stationBranch -and $stationDirty.Count -eq 0) {
    Write-Host "  ok   branch $stationBranch, sem alterações" -ForegroundColor DarkGray
}

if ($problems -gt 0) {
    Write-Host "`nNada foi gravado. Resolva o(s) $problems problema(s) acima e rode de novo." -ForegroundColor Red
    exit 1
}

# --- 3. O repos.lock ----------------------------------------------------------
$nameWidth = ($rows | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
$urlWidth = ($rows | ForEach-Object { $_.Url.Length } | Measure-Object -Maximum).Maximum
$lines = @(
    "# repos.lock: gerado por tools/congelar.ps1. Não edite à mão.",
    "#",
    "# Versão da estação: $Versao",
    "# Congelada em:      $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')",
    "#",
    "# Mesmo formato do repos.txt, com o commit exato no lugar da branch. Para",
    "# pôr a estação nesta versão:",
    "#",
    "#     git checkout $Versao",
    "#     .\bootstrap.ps1 -Lock        (ou ./bootstrap.sh --lock)",
    "#",
    "# O comentário no fim de cada linha é a branch em que o commit estava.",
    ""
)
foreach ($r in $rows) {
    $lines += ("{0}  {1}  {2}  # {3}" -f $r.Name.PadRight($nameWidth), $r.Url.PadRight($urlWidth), $r.Sha, $r.Branch)
}
$lockText = ($lines -join "`n") + "`n"

if ($DryRun) {
    Write-Host "`n=== 3. SIMULAÇÃO: este seria o repos.lock ===" -ForegroundColor Cyan
    Write-Host $lockText
    Write-Host "Tudo certo. Rode sem -DryRun para gravar o lock e criar a tag $Versao." -ForegroundColor Green
    exit 0
}

Write-Host "`n=== 3. Gravando a versão $Versao ===" -ForegroundColor Cyan
[System.IO.File]::WriteAllText($lockFile, $lockText, $utf8NoBom)

# Mensagens por arquivo (-F), e não por -m: o PowerShell 5.1 passa acento em
# argumento de programa externo pela página de código do console, e o "Versão"
# chegaria ao git estragado.
$summary = ($rows | ForEach-Object { "{0}  {1}  {2}" -f $_.Name.PadRight($nameWidth), (Get-Short $_.Sha), $_.Branch }) -join "`n"
$msgFile = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($msgFile, "Versão $($Versao): congela os $($rows.Count) repositórios em repos.lock`n`n$summary`n", $utf8NoBom)
    git -C $root add -- repos.lock
    git -C $root commit --quiet -F $msgFile -- repos.lock
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  o commit do repos.lock falhou; nenhuma tag foi criada." -ForegroundColor Red
        exit 1
    }

    [System.IO.File]::WriteAllText($msgFile, "Estação $Versao`n`n$summary`n", $utf8NoBom)
    git -C $root tag -a $Versao -F $msgFile
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  a criação da tag falhou. O repos.lock já está commitado; crie a tag à mão: git tag -a $Versao" -ForegroundColor Red
        exit 1
    }
} finally {
    Remove-Item $msgFile -ErrorAction SilentlyContinue
}

$commit = Get-Short (git -C $root rev-parse HEAD)
Write-Host "  ok   repos.lock commitado em $stationBranch ($commit), tag $Versao criada" -ForegroundColor DarkGray

if ($Publicar) {
    git -C $root push origin "refs/tags/$Versao"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  o push da tag falhou. A versão existe aqui; tente de novo: git push origin $Versao" -ForegroundColor Red
        exit 1
    }
    Write-Host "  ok   tag enviada ao GitHub" -ForegroundColor DarkGray
}

Write-Host "`nVersão $Versao congelada." -ForegroundColor Green
if (-not $Publicar) {
    Write-Host "Ela só existe nesta máquina até você enviar a tag: git push origin $Versao"
}
Write-Host @"

Para voltar a esta versão depois:
    git checkout $Versao
    .\bootstrap.ps1 -Lock
    docker compose up -d --build
"@
