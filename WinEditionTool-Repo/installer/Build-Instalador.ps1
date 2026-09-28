# Build-Instalador.ps1
# Compila o Install.ps1 num Instalador.exe standalone (pede elevacao de admin
# sozinho, sem precisar abrir PowerShell manualmente). Precisa rodar isso
# so uma vez, numa maquina com internet (pra baixar o modulo ps2exe).
#
# Depois de gerado, o pacote pra distribuir e:
#   Instalador.exe  +  WinEditionTool.exe (opcional, se ja tiver)  +  README.md (opcional)
# tudo na mesma pasta. Quem for instalar so precisa dar 2 cliques no
# Instalador.exe.

$ErrorActionPreference = "Stop"

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "Instalando modulo ps2exe..." -ForegroundColor Cyan
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

$origem = Join-Path $PSScriptRoot "Install.ps1"
$destino = Join-Path $PSScriptRoot "Instalador.exe"

Invoke-ps2exe `
    -inputFile $origem `
    -outputFile $destino `
    -title "Instalador - WinEditionTool" `
    -requireAdmin `
    -noConsole:$false

Write-Host ""
Write-Host "Instalador.exe gerado em: $destino" -ForegroundColor Green
Write-Host "Distribua esse arquivo junto com o WinEditionTool.exe (ou o src\WinEditionTool.ps1," -ForegroundColor Cyan
Write-Host "que o instalador compila sozinho se nao achar o .exe pronto)." -ForegroundColor Cyan
