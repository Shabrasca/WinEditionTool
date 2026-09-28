<#
    Build-EXE.ps1
    Roda UMA VEZ, no Windows, dentro desta pasta, para gerar o WinEditionTool.exe
    a partir do WinEditionTool.ps1 (usa o modulo publico "ps2exe").

    Uso:
      cd "caminho\desta\pasta"
      .\Build-EXE.ps1

    Depois disso, o arquivo WinEditionTool.exe pode ser copiado para qualquer
    computador/empresa e usado sozinho (nao precisa mais do PowerShell nem
    deste script de build).
#>

$ErrorActionPreference = "Stop"

Write-Host "Verificando o modulo ps2exe..." -ForegroundColor Cyan
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "Instalando ps2exe (precisa de internet, so acontece uma vez)..." -ForegroundColor Yellow
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe -Force

$src = Join-Path $PSScriptRoot "WinEditionTool.ps1"
$out = Join-Path $PSScriptRoot "WinEditionTool.exe"

if (-not (Test-Path $src)) {
    Write-Error "Nao encontrei WinEditionTool.ps1 nesta pasta. Rode este script de dentro da pasta correta."
    exit 1
}

Write-Host "Compilando $out ..." -ForegroundColor Cyan

Invoke-ps2exe -inputFile $src -outputFile $out `
    -noConsole `
    -title "WinEditionTool" `
    -product "WinEditionTool" `
    -description "Troca a edicao do Windows (Pro -> Education/Enterprise/etc) remotamente" `
    -company "Sua Empresa" `
    -version "1.0.0.0" `
    -requireAdmin

Write-Host ""
Write-Host "Pronto! Gerado: $out" -ForegroundColor Green
Write-Host "Esse arquivo .exe ja pode ser copiado e usado em qualquer computador Windows." -ForegroundColor Green
