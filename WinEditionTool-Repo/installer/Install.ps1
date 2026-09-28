# Install.ps1
# Instalador do WinEditionTool. Copia o executavel pra uma pasta fixa da
# maquina, cria atalhos (Desktop + Menu Iniciar) e prepara a pasta de dados
# (WinEditionTool-Files). Pensado pra ser rodado uma vez em cada maquina de
# gestao de TI onde a ferramenta vai ser usada.
#
# Pode ser rodado direto como .ps1, ou compilado em Instalador.exe com
# Build-Instalador.ps1 (mesma tecnica do Build-EXE.ps1 principal), pra virar
# um instalador clicavel de verdade.
#
# O QUE ELE FAZ:
#   1. Verifica se ha PowerShell 5.1+ (requisito minimo da ferramenta).
#   2. Copia (ou gera, se so tiver o .ps1) o WinEditionTool.exe pra
#      C:\Program Files\WinEditionTool\.
#   3. Cria atalho no Desktop e no Menu Iniciar.
#   4. Cria a pasta de dados WinEditionTool-Files ao lado do .exe instalado.
#   5. Nao mexe em nenhuma outra maquina, nao aplica nenhuma chave - so
#      instala a ferramenta localmente.
#
# REQUISITOS: rodar como Administrador (precisa gravar em Program Files).

#Requires -RunAsAdministrator

param(
    [string]$PastaOrigem = $PSScriptRoot,
    [string]$PastaInstalacao = "$env:ProgramFiles\WinEditionTool"
)

$ErrorActionPreference = "Stop"

function Write-Passo($msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}

Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  Instalador do WinEditionTool" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow

# 1. Verifica versao do PowerShell
Write-Passo "Verificando requisitos..."
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "ERRO: e necessario PowerShell 5.1 ou superior. Versao atual: $($PSVersionTable.PSVersion)" -ForegroundColor Red
    exit 1
}
Write-Host "  PowerShell $($PSVersionTable.PSVersion) - OK" -ForegroundColor Green

# 2. Localiza o .exe (ou gera a partir do .ps1 se preciso)
Write-Passo "Procurando o WinEditionTool.exe..."

$exeOrigem = $null
$candidatos = @(
    (Join-Path $PastaOrigem "WinEditionTool.exe"),
    (Join-Path $PastaOrigem "..\build\WinEditionTool.exe"),
    (Join-Path $PastaOrigem "..\src\WinEditionTool.exe")
)
foreach ($c in $candidatos) {
    if (Test-Path $c) { $exeOrigem = (Resolve-Path $c).Path; break }
}

if (-not $exeOrigem) {
    Write-Host "  .exe nao encontrado ao lado do instalador. Tentando gerar a partir do .ps1..." -ForegroundColor Yellow
    $psOrigem = Join-Path $PastaOrigem "..\src\WinEditionTool.ps1"
    if (-not (Test-Path $psOrigem)) {
        Write-Host "ERRO: nao encontrei nem WinEditionTool.exe nem src\WinEditionTool.ps1." -ForegroundColor Red
        Write-Host "Coloque o Install.ps1 na mesma pasta do WinEditionTool.exe, ou mantenha a estrutura do repositorio (src\, build\, installer\)." -ForegroundColor Red
        exit 1
    }
    if (-not (Get-Module -ListAvailable -Name ps2exe)) {
        Write-Host "  Instalando modulo ps2exe (necessario pra compilar o .exe)..." -ForegroundColor Yellow
        Install-Module -Name ps2exe -Scope CurrentUser -Force -ErrorAction Stop
    }
    Import-Module ps2exe -ErrorAction Stop
    $exeGerado = Join-Path $env:TEMP "WinEditionTool.exe"
    Invoke-ps2exe -inputFile $psOrigem -outputFile $exeGerado -noConsole -requireAdmin -title "WinEditionTool" -ErrorAction Stop
    $exeOrigem = $exeGerado
    Write-Host "  .exe gerado com sucesso." -ForegroundColor Green
} else {
    Write-Host "  Encontrado: $exeOrigem" -ForegroundColor Green
}

# 3. Copia pra pasta de instalacao
Write-Passo "Instalando em $PastaInstalacao ..."
if (-not (Test-Path $PastaInstalacao)) {
    New-Item -ItemType Directory -Path $PastaInstalacao -Force | Out-Null
}
$exeDestino = Join-Path $PastaInstalacao "WinEditionTool.exe"
Copy-Item -Path $exeOrigem -Destination $exeDestino -Force

# Copia tambem LEIAME/README, se existir, pra referencia local
foreach ($doc in @("LEIAME.txt", "README.md")) {
    $docOrigem = Join-Path $PastaOrigem "..\$doc"
    if (Test-Path $docOrigem) {
        Copy-Item -Path $docOrigem -Destination (Join-Path $PastaInstalacao $doc) -Force
    }
}

Write-Host "  Copiado para $exeDestino" -ForegroundColor Green

# 4. Prepara a pasta de dados (WinEditionTool-Files) - so cria vazia, a
#    ferramenta preenche sozinha na primeira execucao
$pastaDados = Join-Path $PastaInstalacao "WinEditionTool-Files"
if (-not (Test-Path $pastaDados)) {
    New-Item -ItemType Directory -Path $pastaDados -Force | Out-Null
    Write-Host "  Pasta de dados criada: $pastaDados" -ForegroundColor Green
}

# 5. Cria atalhos
Write-Passo "Criando atalhos..."
$shell = New-Object -ComObject WScript.Shell

$atalhoDesktop = Join-Path ([Environment]::GetFolderPath("Desktop")) "WinEditionTool.lnk"
$lnk = $shell.CreateShortcut($atalhoDesktop)
$lnk.TargetPath = $exeDestino
$lnk.WorkingDirectory = $PastaInstalacao
$lnk.Description = "WinEditionTool - Gerenciar edicao/licenciamento do Windows em lote"
$lnk.Save()
Write-Host "  Atalho no Desktop criado." -ForegroundColor Green

$pastaMenuIniciar = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs"
$atalhoMenu = Join-Path $pastaMenuIniciar "WinEditionTool.lnk"
$lnk2 = $shell.CreateShortcut($atalhoMenu)
$lnk2.TargetPath = $exeDestino
$lnk2.WorkingDirectory = $PastaInstalacao
$lnk2.Description = "WinEditionTool - Gerenciar edicao/licenciamento do Windows em lote"
$lnk2.Save()
Write-Host "  Atalho no Menu Iniciar criado." -ForegroundColor Green

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  Instalacao concluida!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "Local: $PastaInstalacao"
Write-Host "Abra pelo atalho no Desktop ou no Menu Iniciar."
Write-Host ""
