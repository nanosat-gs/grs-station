<#
.SYNOPSIS
    SÓ DESENVOLVIMENTO: esvazia os dados de recepção e telemetria de TESTE, com backup antes.

.DESCRIPTION
    Ferramenta de teste. NÃO é para a estação em produção, e se recusa a rodar
    nela. Há duas travas, e nenhum parâmetro passa por cima delas:

      1. AMBIENTE DECLARADO: só roda com STATION_ENV=desenvolvimento, no .env
         do grs-station ou no ambiente do PowerShell. Sem a variável, ou com
         qualquer outro valor (producao, por exemplo), recusa. Na dúvida,
         não apaga.
      2. RÁDIO REAL LIGADO: se um receptor de verdade estiver rodando (USRP VHF,
         USRP UHF ou RTL-SDR), recusa mesmo em desenvolvimento, porque os
         pacotes no banco podem ser de satélite, e não do simulador.

    Apaga o conteúdo das três tabelas que o caminho de recepção enche:

        mission_control.raw_packets            os pacotes crus (archivers VHF e UHF)
        mission_control.decoded_frames         o resultado de cada pacote (decoder)
        mission_control.fs2_general_telemetry  os campos do General Telemetry (decoder)

    e recomeça a numeração do 1. Não toca em mais nada: satélites, passagens,
    telecomandos, downlinks e o índice de capturas de IQ ficam como estão.

    Passos, na ordem (depois das travas):

      1. backup das três tabelas em backups\recepcao-<data-hora>.sql.gz
      2. para os serviços que gravam nelas (os dois archivers e o decoder), para
         nenhum pacote entrar no meio da limpeza
      3. TRUNCATE ... RESTART IDENTITY
      4. religa os serviços que estavam rodando, e só esses

    Para que serve: tirar dado de teste (simulador, padrão 00 01 02...) da
    máquina de desenvolvimento. Os dados são apagados de verdade; o backup é a
    única volta.

    Na estação de produção, ponha STATION_ENV=producao no .env. Dado de
    satélite não se apaga: o raw_packets é append-only por desenho, e é dele
    que o decoder reprocessa o histórico.

.PARAMETER SemBackup
    Não faz o backup. Só use se o que está no banco não vale nada.

.PARAMETER Force
    Não pede confirmação. NÃO desliga as travas.

.EXAMPLE
    .\tools\limpar-dados-de-teste.ps1
    .\tools\limpar-dados-de-teste.ps1 -Force
    .\tools\limpar-dados-de-teste.ps1 -SemBackup -Force

.NOTES
    Para restaurar um backup (com as tabelas vazias, por exemplo logo depois de
    rodar este script):

        docker cp backups\recepcao-<data-hora>.sql.gz spacelab-postgres:/tmp/restaurar.sql.gz
        docker exec spacelab-postgres sh -c "gunzip -c /tmp/restaurar.sql.gz | psql -U admin -d tc_generator"
#>
[CmdletBinding()]
param(
    [switch]$SemBackup,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$stationRoot = Split-Path -Parent $PSScriptRoot

# Os receptores de RÁDIO REAL. Os simuladores (grs-sdr-sim*) e o replay não
# entram aqui: o que eles põem no banco é teste por definição.
$realReceivers = @(
    "spacelab-grs-iq-rx-usrp",
    "spacelab-grs-iq-rx-usrp-uhf",
    "spacelab-grs-iq-rx"
)

function Get-StationEnv {
    # Mesma precedência do docker compose: o ambiente do processo vence o .env.
    if ($env:STATION_ENV) { return $env:STATION_ENV.Trim() }
    $envFile = Join-Path $stationRoot ".env"
    if (Test-Path $envFile) {
        foreach ($line in Get-Content $envFile) {
            if ($line -match '^\s*STATION_ENV\s*=\s*(.*?)\s*$') { return $Matches[1].Trim('"', "'") }
        }
    }
    return $null
}

# --- trava 1: ambiente declarado ----------------------------------------------------

$stationEnv = Get-StationEnv
if ($stationEnv -ne "desenvolvimento") {
    $shown = if ($stationEnv) { "STATION_ENV=$stationEnv" } else { "STATION_ENV não definida" }
    Write-Host "RECUSADO: $shown." -ForegroundColor Red
    Write-Host "Esta ferramenta apaga dados e só roda em máquina de desenvolvimento, com"
    Write-Host "STATION_ENV=desenvolvimento no .env do grs-station. Nada foi apagado."
    exit 2
}

$postgres = "spacelab-postgres"
$dbUser = if ($env:DB_USER) { $env:DB_USER } else { "admin" }
$dbName = if ($env:DB_NAME) { $env:DB_NAME } else { "tc_generator" }

# Ordem importa só no TRUNCATE (as FKs): ele recebe as três de uma vez.
$tables = @(
    "mission_control.fs2_general_telemetry",
    "mission_control.decoded_frames",
    "mission_control.raw_packets"
)
# Quem grava nessas tabelas. Parar antes e religar depois.
$writers = @(
    "spacelab-grs-packet-archiver",
    "spacelab-grs-packet-archiver-uhf",
    "spacelab-grs-telemetry-decoder"
)

function Invoke-Psql {
    param([string]$Sql)
    $output = docker exec $postgres psql -U $dbUser -d $dbName -tA -c $Sql
    if ($LASTEXITCODE -ne 0) { throw "psql falhou: $Sql" }
    return $output
}

function Get-Counts {
    $sql = ($tables | ForEach-Object { "(select count(*) from $_)" }) -join " || ' / ' || "
    return Invoke-Psql "select $sql"
}

# --- o banco está de pé? ----------------------------------------------------------

$running = docker ps --format "{{.Names}}"
if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker não respondeu. O Docker Desktop está aberto?" -ForegroundColor Red
    exit 1
}
if ($running -notcontains $postgres) {
    Write-Host "O container $postgres não está rodando. Suba a estação antes (docker compose up -d)." -ForegroundColor Red
    exit 1
}

# --- trava 2: rádio real ligado -----------------------------------------------------

$liveRadios = @($realReceivers | Where-Object { $running -contains $_ })
if ($liveRadios.Count -gt 0) {
    Write-Host "RECUSADO: há receptor de rádio real rodando: $($liveRadios -join ', ')." -ForegroundColor Red
    Write-Host "Os pacotes no banco podem ser de satélite, e não do simulador. Nada foi apagado."
    exit 2
}

# Tabelas que ainda não existem (o decoder nunca subiu contra este banco) ficam
# de fora, em vez de derrubar o TRUNCATE inteiro.
$tables = @($tables | Where-Object { (Invoke-Psql "select to_regclass('$_') is not null") -eq "t" })
if ($tables.Count -eq 0) {
    Write-Host "Nenhuma tabela de recepção no banco: nada a limpar." -ForegroundColor Yellow
    exit 0
}

Write-Host "`nTabelas: $($tables -join ', ')"
Write-Host "Linhas agora (na mesma ordem): $(Get-Counts)"

if (-not $Force) {
    $answer = Read-Host "`nApagar tudo isso? Digite 'sim' para confirmar"
    if ($answer -ne "sim") {
        Write-Host "Nada foi apagado."
        exit 0
    }
}

# --- 1. backup --------------------------------------------------------------------

if (-not $SemBackup) {
    $backupDir = Join-Path $stationRoot "backups"
    New-Item -ItemType Directory -Force $backupDir | Out-Null
    $stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $file = Join-Path $backupDir "recepcao-$stamp.sql.gz"
    $tableArgs = ($tables | ForEach-Object { "-t $_" }) -join " "

    Write-Host "`n=== backup ===" -ForegroundColor Cyan
    # Gerado DENTRO do container e copiado depois: o pipe do PowerShell 5.1
    # trata saída como texto e corromperia o .gz no caminho.
    docker exec $postgres sh -c "pg_dump -U $dbUser -d $dbName --data-only $tableArgs | gzip > /tmp/backup-recepcao.sql.gz"
    if ($LASTEXITCODE -ne 0) { throw "pg_dump falhou; nada foi apagado." }
    docker cp "${postgres}:/tmp/backup-recepcao.sql.gz" $file | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "não consegui copiar o backup; nada foi apagado." }
    docker exec $postgres rm -f /tmp/backup-recepcao.sql.gz | Out-Null
    $sizeMb = [math]::Round((Get-Item $file).Length / 1MB, 1)
    Write-Host "  $file ($sizeMb MB)"
}

# --- 2 a 4. parar, limpar, religar ------------------------------------------------

$stopped = @($writers | Where-Object { $running -contains $_ })
try {
    if ($stopped.Count -gt 0) {
        Write-Host "`n=== parando quem grava: $($stopped -join ', ') ===" -ForegroundColor Cyan
        docker stop $stopped | Out-Null
    }

    Write-Host "`n=== limpando ===" -ForegroundColor Cyan
    Invoke-Psql "TRUNCATE $($tables -join ', ') RESTART IDENTITY" | Out-Null
    Write-Host "  linhas agora: $(Get-Counts)"
}
finally {
    # Religa mesmo se a limpeza falhar: a estação não pode ficar sem archiver
    # por causa de um script de manutenção.
    if ($stopped.Count -gt 0) {
        Write-Host "`n=== religando ===" -ForegroundColor Cyan
        docker start $stopped | Out-Null
    }
}

Write-Host "`nPronto. Os pacotes novos voltam a entrar a partir do id 1." -ForegroundColor Green
