<#
.SYNOPSIS
    Roda a suíte de cada repositório clonado, mais o teste ponta a ponta.

.DESCRIPTION
    Restaura o que o monorepo dava de graça: um comando só cobrindo tudo.

    Sem isto, uma mudança em spacelab_tracking.coordinates que quebre
    mgm8.infrastructure.sgp4_pointing não é pega localmente — cada repo passa
    nos próprios testes e a falha só aparece quando a estação sobe.

    Exige `.\bootstrap.ps1 -Dev` antes, para que os repos estejam instalados em
    modo editável e o e2e enxergue as árvores de trabalho.
#>
[CmdletBinding()]
param()

$root = $PSScriptRoot
$failed = @()

foreach ($name in @("spacelab-tracking", "grs-station-manager", "grs-manager", "grs-tc-scheduler",
                        "grs-iq-recorder", "grs-sdr-sim", "grs-demodulator")) {
    $path = Join-Path $root "repos\$name"
    if (-not (Test-Path $path)) {
        Write-Warning "pulando $name (nao clonado)"
        continue
    }
    Write-Host "`n=== $name ===" -ForegroundColor Cyan
    Push-Location $path
    python -m pytest -q
    if ($LASTEXITCODE -ne 0) { $failed += $name }
    Pop-Location
}

Write-Host "`n=== ponta a ponta (grs-station) ===" -ForegroundColor Cyan
Push-Location $root
python -m pytest -q
if ($LASTEXITCODE -ne 0) { $failed += "grs-station (e2e)" }
Pop-Location

Write-Host ""
if ($failed.Count -gt 0) {
    Write-Host ("FALHOU: " + ($failed -join ", ")) -ForegroundColor Red
    exit 1
}
Write-Host "Tudo verde." -ForegroundColor Green
