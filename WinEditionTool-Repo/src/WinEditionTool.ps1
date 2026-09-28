<#
    WinEditionTool
    Ferramenta com interface grafica para:
      (1) Trocar a edicao do Windows (Pro -> Education / Enterprise / Pro
          Education / etc) remotamente, via WMI + compartilhamento
          administrativo (C$) - nao depende de WinRM.
      (2) Verificar se maquinas com Windows 10 sao elegiveis para o upgrade
          de VERSAO pra Windows 11 (TPM 2.0, Secure Boot, RAM, disco, CPU) -
          so verifica, nao faz o upgrade de versao (isso e outra etapa,
          bem mais pesada, feita depois separadamente).

    Na primeira execucao, cria (ao lado do .exe/.ps1):
      .\WinEditionTool-Files\Upgrade-Edition.ps1          -> roda na maquina remota (troca de edicao)
      .\WinEditionTool-Files\Check-Win11-Eligibility.ps1  -> roda na maquina remota (checagem Win11)
      .\WinEditionTool-Files\historico.csv                -> historico de trocas de edicao aplicadas
      .\WinEditionTool-Files\historico_elegibilidade.csv  -> historico de checagens de elegibilidade

    Empacotamento em .exe: ver Build-EXE.ps1 / LEIAME.txt nesta mesma pasta.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# 0. Pasta base (funciona rodando como .ps1 OU como .exe compilado com ps2exe)
# ---------------------------------------------------------------------------
try {
    $baseDir = if ($PSScriptRoot) { $PSScriptRoot }
               else { Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
} catch {
    $baseDir = (Get-Location).Path
}

$filesDir   = Join-Path $baseDir "WinEditionTool-Files"
$remoteScriptPath        = Join-Path $filesDir "Upgrade-Edition.ps1"
$remoteCheckScriptPath   = Join-Path $filesDir "Check-Win11-Eligibility.ps1"
$remoteUpgradeOSPath     = Join-Path $filesDir "Upgrade-Win11-Versao.ps1"
$remoteLicenseCheckPath  = Join-Path $filesDir "Check-Licenca.ps1"
$historyPath        = Join-Path $filesDir "historico.csv"
$historyCheckPath   = Join-Path $filesDir "historico_elegibilidade.csv"
$historyUpgradePath = Join-Path $filesDir "historico_upgrade_win11.csv"
$historyLicensePath = Join-Path $filesDir "historico_licenca.csv"

if (-not (Test-Path $filesDir)) { New-Item -ItemType Directory -Path $filesDir -Force | Out-Null }

# ---------------------------------------------------------------------------
# 1a. Script que roda DENTRO da maquina remota - troca de edicao
# ---------------------------------------------------------------------------
$remoteScriptContent = @'
<#
  Roda localmente na maquina de destino (disparado via WMI pelo WinEditionTool).
  Aplica a chave de produto informada e agenda o reinicio com aviso ao usuario.
#>
param(
    [string]$TargetEditionId = "Education",
    [string]$TargetEditionLabel = "Education",
    [string]$ProductKey,
    [int]$GraceDays = 3,
    [switch]$ForceReactivate
)

$ErrorActionPreference = "Stop"
$LogDir  = "C:\ProgramData\WinEditionTool"
$LogPath = Join-Path $LogDir "upgrade.log"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $LogPath -Value $line
    Write-Output $line
}

$currentEdition = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").EditionID
Write-Log "Edicao atual detectada (EditionID): $currentEdition"

# Status de ativacao ATUAL, independente da edicao - e o que detecta o caso
# "edicao ja esta certa, mas o Windows ainda mostra 'Ative o Windows'".
$dliOutput = cscript.exe //nologo "$env:WINDIR\System32\slmgr.vbs" /dli 2>&1 | Out-String
$dliOneLine = ($dliOutput -replace "[\r\n]+", " | ").Trim()
Write-Log "Status de licenciamento atual (slmgr /dli): $dliOneLine"
$isActivated = $dliOutput -match "licenciado permanentemente|licensed permanently|licenca permanente|permanently licensed"

# Comparacao EXATA (nao "contem"), senao "Education" seria considerado igual
# a "ProfessionalEducation" (Pro Education) por ser substring, por exemplo.
if ($currentEdition -eq $TargetEditionId -and $isActivated -and -not $ForceReactivate) {
    Write-Log "Maquina ja esta na edicao alvo ($TargetEditionLabel) e ja esta ativada. Nada a fazer."
    exit 0
}

if (-not $ProductKey) {
    Write-Log "ERRO: nenhuma chave de produto informada. Abortando."
    exit 1
}

$markerPath = "HKLM:\SOFTWARE\WinEditionTool\Upgrade"
New-Item -Path $markerPath -Force | Out-Null

if ($currentEdition -eq $TargetEditionId -and -not $isActivated) {
    Write-Log "Edicao ja e a correta, mas a ativacao parece pendente/invalida (mensagem 'Ative o Windows') - reaplicando chave e reativando..."
} elseif ($ForceReactivate) {
    Write-Log "Reaplicacao forcada solicitada - reaplicando chave e reativando mesmo que ja parecesse OK..."
}

# A partir daqui SEMPRE tenta aplicar a chave/ativar de novo (nao ha mais o
# antigo bloqueio "ja foi aplicado antes, nao mexe"), pois e exatamente isso
# que resolve tanto a troca de edicao quanto o "Ative o Windows" persistente.
Write-Log "Instalando chave de produto ($TargetEditionLabel) via slmgr /ipk..."
$ipkOutput = cscript.exe //nologo "$env:WINDIR\System32\slmgr.vbs" /ipk $ProductKey 2>&1 | Out-String
Write-Log "slmgr /ipk resultado: $($ipkOutput.Trim())"

Write-Log "Tentando ativar via slmgr /ato..."
$atoOutput = cscript.exe //nologo "$env:WINDIR\System32\slmgr.vbs" /ato 2>&1 | Out-String
Write-Log "slmgr /ato resultado: $($atoOutput.Trim())"

if ($atoOutput -match "0xC004E028") {
    Write-Log "Ativacao pendente de reinicio (erro 0xC004E028 e esperado - a troca de edicao so completa apos reboot)."
} elseif ($atoOutput -match "0x8007232B|0xC004F074|nao foi possivel contatar|could not be contacted|DNS") {
    Write-Log "AVISO: erro de rede/servidor de ativacao (KMS/Microsoft). Confira se a maquina tem acesso a internet ou ao KMS interno e tente novamente depois."
} elseif ($atoOutput -notmatch "com.*xito|successfully|ativado") {
    Write-Log "AVISO: saida do /ato nao confirmou ativacao explicitamente. Prosseguindo - o reinicio deve resolver."
}

$newEdition = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").EditionID
Write-Log "Edicao apos aplicar a chave (antes do reboot): $newEdition"

$deadline = (Get-Date).AddDays($GraceDays)
Set-ItemProperty -Path $markerPath -Name "KeyApplied" -Value 1 -Type DWord
Set-ItemProperty -Path $markerPath -Name "Deadline" -Value $deadline.ToString("o") -Type String
Set-ItemProperty -Path $markerPath -Name "AppliedAt" -Value (Get-Date).ToString("o") -Type String
Write-Log "Chave aplicada. Reinicio pendente para concluir a troca/ativacao. Prazo limite: $deadline"

$notifyScriptPath = "C:\ProgramData\WinEditionTool\Notify-RestartPending.ps1"
$notifyScriptContent = @"
`$markerPath = "HKLM:\SOFTWARE\WinEditionTool\Upgrade"
`$marker = Get-ItemProperty -Path `$markerPath -ErrorAction SilentlyContinue
if (-not `$marker -or -not `$marker.KeyApplied) { exit 0 }

`$currentEdition = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").EditionID
if (`$currentEdition -eq "$TargetEditionId") {
    Remove-ItemProperty -Path `$markerPath -Name "KeyApplied","Deadline","AppliedAt" -ErrorAction SilentlyContinue
    exit 0
}

`$deadline = [datetime]::Parse(`$marker.Deadline)
`$remaining = `$deadline - (Get-Date)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (`$remaining.TotalMinutes -le 15) {
    [System.Windows.Forms.MessageBox]::Show("Esta estacao sera reiniciada em 15 minutos para concluir uma atualizacao obrigatoria do Windows.``n``nSalve seu trabalho agora.","Reinicio obrigatorio",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    shutdown.exe /r /t 900 /c "Atualizacao obrigatoria do Windows" /f
    exit 0
}

`$horas = [math]::Round(`$remaining.TotalHours,1)
`$msg = "Esta estacao precisa reiniciar para concluir uma atualizacao do Windows.``n``nPrazo final: `$(`$deadline.ToString('dd/MM HH:mm')) (faltam aprox. `$horas h).``n``nDeseja reiniciar agora?"
`$result = [System.Windows.Forms.MessageBox]::Show(`$msg,"Atualizacao pendente",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Information)
if (`$result -eq [System.Windows.Forms.DialogResult]::Yes) { shutdown.exe /r /t 60 /c "Atualizacao do Windows" }
"@
Set-Content -Path $notifyScriptPath -Value $notifyScriptContent -Encoding UTF8
Write-Log "Script de notificacao gravado em $notifyScriptPath"

$taskLogon = "WinEditionTool-Aviso-Logon"
$taskHourly = "WinEditionTool-Aviso-Periodico"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$notifyScriptPath`""
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn
$triggerHourly = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 2) -RepetitionDuration (New-TimeSpan -Days 365)
$principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users" -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

foreach ($t in @(@{Name=$taskLogon;Trigger=$triggerLogon}, @{Name=$taskHourly;Trigger=$triggerHourly})) {
    Unregister-ScheduledTask -TaskName $t.Name -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $t.Name -Action $action -Trigger $t.Trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Log "Tarefa agendada '$($t.Name)' registrada."
}

Write-Log "Concluido nesta maquina."

# Autolimpeza: remove a copia deste script de C:\Windows\Temp na maquina remota.
# (o script ja foi totalmente carregado na memoria pelo powershell.exe neste ponto,
# entao apagar o arquivo agora nao interrompe a execucao)
try {
    Remove-Item -Path $MyInvocation.MyCommand.Path -Force -ErrorAction Stop
    Write-Log "Copia temporaria do script removida de C:\Windows\Temp (autolimpeza)."
} catch {
    Write-Log "Nao foi possivel remover a copia temporaria do script: $($_.Exception.Message)"
}

exit 0
'@

# ---------------------------------------------------------------------------
# 1b. Script que roda DENTRO da maquina remota - checagem de elegibilidade Win11
# ---------------------------------------------------------------------------
$remoteCheckScriptContent = @'
<#
  Roda localmente na maquina de destino (disparado via WMI pelo WinEditionTool).
  So VERIFICA e reporta - nao instala nem muda nada na maquina.
#>
$ErrorActionPreference = "Stop"
$LogDir  = "C:\ProgramData\WinEditionTool"
$LogPath = Join-Path $LogDir "win11check.log"
$CsvPath = Join-Path $LogDir "win11check.csv"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $LogPath -Value $line
    Write-Output $line
}

$falhas = New-Object System.Collections.Generic.List[string]

# --- ja e Windows 11? ---
$os = Get-CimInstance -ClassName Win32_OperatingSystem
Write-Log "Sistema atual: $($os.Caption) (build $($os.BuildNumber))"
if ($os.Caption -match "Windows 11") {
    Write-Log "Esta maquina ja esta no Windows 11. Nada a verificar."
    [PSCustomObject]@{
        Computador=$env:COMPUTERNAME; SistemaAtual=$os.Caption; TPM2=""; SecureBoot=""; RAM_GB="";
        DiscoLivre_GB=""; CPU=""; Nucleos=""; Resultado="JA_WINDOWS11"; Detalhe="Ja esta no Windows 11"
    } | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    exit 0
}

# --- TPM 2.0 ---
$tpm2 = $false
try {
    $tpmObj = Get-CimInstance -Namespace "root/cimv2/Security/MicrosoftTpm" -ClassName Win32_Tpm -ErrorAction Stop
    if ($tpmObj -and $tpmObj.SpecVersion -match "2\.0") { $tpm2 = $true }
    Write-Log "TPM SpecVersion: $($tpmObj.SpecVersion) -> TPM2=$tpm2"
} catch {
    Write-Log "Nao foi possivel consultar o TPM: $($_.Exception.Message)"
    $falhas.Add("TPM nao verificavel/ausente")
}
if (-not $tpm2) { $falhas.Add("Sem TPM 2.0") }

# --- Secure Boot / UEFI ---
$secureBoot = $false
try {
    $secureBoot = [bool](Confirm-SecureBootUEFI)
    Write-Log "Secure Boot: $secureBoot"
} catch {
    Write-Log "Confirm-SecureBootUEFI falhou (provavel BIOS legado, sem UEFI): $($_.Exception.Message)"
    $falhas.Add("Sem UEFI/Secure Boot")
}

# --- RAM ---
$ramGB = [math]::Round(((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory)/1GB, 1)
$ramOk = $ramGB -ge 4
Write-Log "RAM: $ramGB GB -> OK=$ramOk"
if (-not $ramOk) { $falhas.Add("RAM abaixo de 4 GB ($ramGB GB)") }

# --- Disco livre no drive do sistema ---
$sysDrive = $env:SystemDrive
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$sysDrive'"
$freeGB = [math]::Round($disk.FreeSpace/1GB, 1)
$diskOk = $freeGB -ge 64
Write-Log "Disco livre em $sysDrive : $freeGB GB -> OK=$diskOk"
if (-not $diskOk) { $falhas.Add("Menos de 64 GB livres ($freeGB GB)") }

# --- CPU (checagem basica - nucleos/64bit/clock; geracao exata NAO e conferida) ---
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$cores = $cpu.NumberOfCores
$is64 = [Environment]::Is64BitOperatingSystem
$clockOk = $cpu.MaxClockSpeed -ge 1000
$cpuBasicOk = ($cores -ge 2) -and $is64 -and $clockOk
Write-Log "CPU: $($cpu.Name) | Nucleos=$cores | 64bit=$is64 | ClockOk=$clockOk -> BasicoOK=$cpuBasicOk"
if (-not $cpuBasicOk) { $falhas.Add("CPU abaixo do minimo basico (nucleos/64bit/clock)") }

if ($falhas.Count -eq 0) {
    $resultado = "PROVAVEL_ELEGIVEL"
    $detalhe = "Passou nas checagens basicas. CPU nao foi conferida contra a lista oficial de modelos suportados pela Microsoft - confirme o modelo '$($cpu.Name)' se quiser 100% de certeza."
} else {
    $resultado = "NAO_ELEGIVEL"
    $detalhe = ($falhas -join "; ")
}
Write-Log "Resultado: $resultado - $detalhe"

[PSCustomObject]@{
    Computador     = $env:COMPUTERNAME
    SistemaAtual   = $os.Caption
    TPM2           = $tpm2
    SecureBoot     = $secureBoot
    RAM_GB         = $ramGB
    DiscoLivre_GB  = $freeGB
    CPU            = $cpu.Name
    Nucleos        = $cores
    Resultado      = $resultado
    Detalhe        = $detalhe
} | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8

try {
    Remove-Item -Path $MyInvocation.MyCommand.Path -Force -ErrorAction Stop
    Write-Log "Copia temporaria do script removida de C:\Windows\Temp (autolimpeza)."
} catch {
    Write-Log "Nao foi possivel remover a copia temporaria do script: $($_.Exception.Message)"
}
exit 0
'@

# ---------------------------------------------------------------------------
# 1c. Script que roda DENTRO da maquina remota - upgrade de VERSAO p/ Win11
# ---------------------------------------------------------------------------
# Faz o upgrade completo de versao (Windows 10 -> Windows 11), nao so a
# edicao. Copia a midia de instalacao de um compartilhamento de rede para
# uma pasta local (setup.exe rodando direto de UNC e pouco confiavel num
# upgrade com varios reinicios) e dispara o setup em modo silencioso.
# E um processo longo (30-90+ minutos), entao o script so confirma que
# COMECOU - o acompanhamento e feito depois lendo o log remoto.
$remoteWin11UpgradeContent = @'
param(
    [string]$SetupSharePath,
    [switch]$SkipEligibilityCheck
)
$ErrorActionPreference = "Stop"
$LogDir  = "C:\ProgramData\WinEditionTool"
$LogPath = Join-Path $LogDir "win11upgrade.log"
$LocalMediaDir = "C:\WinEditionTool-Win11Media"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $LogPath -Value $line
    Write-Output $line
}

$os = Get-CimInstance -ClassName Win32_OperatingSystem
Write-Log "Sistema atual: $($os.Caption) (build $($os.BuildNumber))"
if ($os.Caption -match "Windows 11") {
    Write-Log "Esta maquina ja esta no Windows 11. Nada a fazer."
    exit 0
}

if (-not $SkipEligibilityCheck) {
    $falhas = New-Object System.Collections.Generic.List[string]
    try {
        $tpmObj = Get-CimInstance -Namespace "root/cimv2/Security/MicrosoftTpm" -ClassName Win32_Tpm -ErrorAction Stop
        if (-not ($tpmObj -and $tpmObj.SpecVersion -match "2\.0")) { $falhas.Add("Sem TPM 2.0") }
    } catch { $falhas.Add("TPM nao verificavel/ausente") }
    try { if (-not [bool](Confirm-SecureBootUEFI)) { $falhas.Add("Secure Boot desligado") } } catch { $falhas.Add("Sem UEFI/Secure Boot") }
    $ramGB = [math]::Round(((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory)/1GB, 1)
    if ($ramGB -lt 4) { $falhas.Add("RAM abaixo de 4 GB ($ramGB GB)") }
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
    $freeGB = [math]::Round($disk.FreeSpace/1GB, 1)
    if ($freeGB -lt 64) { $falhas.Add("Menos de 64 GB livres ($freeGB GB)") }
    if ($falhas.Count -gt 0) {
        Write-Log "ABORTADO - maquina nao elegivel para Windows 11: $($falhas -join '; ')"
        exit 1
    }
    Write-Log "Checagem basica de elegibilidade OK. Prosseguindo com o upgrade."
}

if (-not $SetupSharePath -or -not (Test-Path $SetupSharePath)) {
    Write-Log "ERRO - caminho de midia de instalacao invalido ou inacessivel: $SetupSharePath"
    exit 1
}

Write-Log "Copiando midia de instalacao de '$SetupSharePath' para '$LocalMediaDir' (robocopy /MIR)..."
New-Item -ItemType Directory -Force -Path $LocalMediaDir | Out-Null
$roboLog = robocopy $SetupSharePath $LocalMediaDir /MIR /R:2 /W:5 /NFL /NDL /NP 2>&1 | Out-String
Write-Log "robocopy concluido (exit aproximado, ver setup.exe abaixo)."

$setupExe = Join-Path $LocalMediaDir "setup.exe"
if (-not (Test-Path $setupExe)) {
    Write-Log "ERRO - setup.exe nao encontrado em '$LocalMediaDir' apos a copia. Confira o compartilhamento de origem."
    exit 1
}

Write-Log "Midia copiada. Disparando setup.exe em modo automatico/silencioso (isso pode levar 30-90+ minutos e reiniciar a maquina varias vezes)..."
$copyLogsDir = Join-Path $LogDir "setuplogs"
New-Item -ItemType Directory -Force -Path $copyLogsDir | Out-Null
$argList = "/auto upgrade /quiet /noreboot /dynamicupdate disable /EULA accept /copylogs `"$copyLogsDir`""

try {
    # -Wait e seguro aqui: este processo ja roda desacoplado do WinEditionTool
    # (foi lancado via WMI Win32_Process.Create, que ja retornou pro
    # gerenciador antes disso), entao bloquear aqui dentro nao trava a GUI.
    $proc = Start-Process -FilePath $setupExe -ArgumentList $argList -PassThru -Wait
    Write-Log "setup.exe finalizou com codigo de saida $($proc.ExitCode)."
    if ($proc.ExitCode -eq 0) {
        Write-Log "Upgrade preparado com sucesso. A maquina deve reiniciar sozinha para concluir (varias vezes). Apos o(s) reinicio(s), confira a versao."
    } else {
        Write-Log "AVISO - setup.exe retornou codigo diferente de 0. Confira os logs em '$copyLogsDir' para detalhes."
    }
} catch {
    Write-Log "ERRO ao iniciar o setup.exe: $($_.Exception.Message)"
    exit 1
}

exit 0
'@

# ---------------------------------------------------------------------------
# 1d. Script que roda DENTRO da maquina remota - checagem de licenciamento
# ---------------------------------------------------------------------------
# So verifica (via slmgr /dli) se a maquina esta ativada e qual edicao tem -
# nao muda nada. Serve para mapear em lote quais maquinas estao mostrando
# "Ative o Windows" ou rodando sem licenca valida.
$remoteLicenseCheckContent = @'
$ErrorActionPreference = "Stop"
$LogDir  = "C:\ProgramData\WinEditionTool"
$LogPath = Join-Path $LogDir "licencacheck.log"
$CsvPath = Join-Path $LogDir "licencacheck.csv"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $LogPath -Value $line
    Write-Output $line
}

$edition = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").EditionID
$os = Get-CimInstance -ClassName Win32_OperatingSystem
$dliOutput = cscript.exe //nologo "$env:WINDIR\System32\slmgr.vbs" /dli 2>&1 | Out-String
$dliOneLine = ($dliOutput -replace "[\r\n]+", " | ").Trim()
Write-Log "Sistema: $($os.Caption) | EditionID: $edition"
Write-Log "slmgr /dli: $dliOneLine"

$isActivated = $dliOutput -match "licenciado permanentemente|licensed permanently|licenca permanente|permanently licensed"
$resultado = if ($isActivated) { "ATIVADO" } else { "NAO_ATIVADO" }
Write-Log "Resultado: $resultado"

[PSCustomObject]@{
    Computador   = $env:COMPUTERNAME
    SistemaAtual = $os.Caption
    EditionID    = $edition
    Ativado      = $isActivated
    Resultado    = $resultado
    Detalhe      = $dliOneLine
} | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8

try {
    Remove-Item -Path $MyInvocation.MyCommand.Path -Force -ErrorAction Stop
    Write-Log "Copia temporaria do script removida (autolimpeza)."
} catch {
    Write-Log "Nao foi possivel remover a copia temporaria do script: $($_.Exception.Message)"
}
exit 0
'@

if (-not (Test-Path $remoteScriptPath)) {
    Set-Content -Path $remoteScriptPath -Value $remoteScriptContent -Encoding UTF8
}
if (-not (Test-Path $remoteCheckScriptPath)) {
    Set-Content -Path $remoteCheckScriptPath -Value $remoteCheckScriptContent -Encoding UTF8
}
# Estes dois sao sobrescritos sempre (nao so na primeira execucao), pois sao
# features novas e uma copia antiga/vazia travaria o usuario sem aviso.
Set-Content -Path $remoteUpgradeOSPath -Value $remoteWin11UpgradeContent -Encoding UTF8
Set-Content -Path $remoteLicenseCheckPath -Value $remoteLicenseCheckContent -Encoding UTF8

if (-not (Test-Path $historyPath)) {
    "Timestamp,Computador,EdicaoAlvo,Status,Detalhe" | Set-Content -Path $historyPath -Encoding UTF8
}
if (-not (Test-Path $historyCheckPath)) {
    "Timestamp,Computador,SistemaAtual,TPM2,SecureBoot,RAM_GB,DiscoLivre_GB,CPU,Nucleos,Resultado,Detalhe" | Set-Content -Path $historyCheckPath -Encoding UTF8
}
if (-not (Test-Path $historyUpgradePath)) {
    "Timestamp,Computador,Status,Detalhe" | Set-Content -Path $historyUpgradePath -Encoding UTF8
}
if (-not (Test-Path $historyLicensePath)) {
    "Timestamp,Computador,SistemaAtual,EditionID,Ativado,Resultado,Detalhe" | Set-Content -Path $historyLicensePath -Encoding UTF8
}

# ---------------------------------------------------------------------------
# 2. Motor de deploy / checagem remota
# ---------------------------------------------------------------------------
$script:cred = $null

function Remove-DangerousChars {
    # tira aspas/crases que poderiam quebrar a linha de comando remota
    param([string]$Text)
    if (-not $Text) { return $Text }
    return ($Text -replace '["`]', '')
}

function New-RemoteDrive {
    param([string]$Computer, [System.Management.Automation.PSCredential]$Credential)
    $driveName = "WET" + (Get-Random -Maximum 99999)
    try { Remove-PSDrive -Name $driveName -Scope Global -ErrorAction SilentlyContinue } catch {}
    # -Scope Global e obrigatorio aqui: sem isso, o PSDrive criado dentro desta
    # funcao e destruido assim que ela retorna (escopo local), e o Copy-Item
    # que roda depois, na funcao chamadora, falha com "Nao e possivel localizar
    # a unidade" mesmo a funcao tendo "criado com sucesso" o drive segundos antes.
    New-PSDrive -Name $driveName -PSProvider FileSystem -Root "\\$Computer\C$" -Credential $Credential -Scope Global -ErrorAction Stop | Out-Null
    return $driveName
}

function Get-FriendlyWmiError {
    param([string]$RawMessage, [string]$Computer)
    if ($RawMessage -match "Multiple connections|multiplas conexoes|already.*connect") {
        return "Ja existe uma conexao (mapeamento de rede) com essa maquina usando outra credencial. Feche janelas do Explorer apontando pra \\$Computer\ ou rode 'net use \\$Computer\C$ /delete' e tente de novo. ($RawMessage)"
    }
    return $RawMessage
}

function Write-HistoryLine {
    # Grava uma linha num CSV de historico com retry, para o caso do arquivo
    # estar momentaneamente aberto/travado por outro programa (ex: Excel).
    # Se mesmo assim nao conseguir gravar apos as tentativas, salva a linha
    # perdida num arquivo ".pendentes" ao lado, para nao perder o registro.
    param(
        [string]$Path,
        [string]$Line,
        [int]$MaxAttempts = 5,
        [int]$DelayMs = 400
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Add-Content -Path $Path -Value $Line -ErrorAction Stop
            return $true
        } catch {
            if ($attempt -lt $MaxAttempts) {
                Start-Sleep -Milliseconds ($DelayMs * $attempt)
            } else {
                try {
                    $pendingPath = "$Path.pendentes"
                    Add-Content -Path $pendingPath -Value $Line -ErrorAction Stop
                } catch {
                    # ultimo recurso: nao ha nada mais a fazer, so nao derruba o programa
                }
                return $false
            }
        }
    }
}

function Invoke-EditionUpgrade {
    param(
        [string]$Computer,
        [string]$EditionId,
        [string]$EditionLabel,
        [string]$ProductKey,
        [int]$GraceDays,
        [System.Management.Automation.PSCredential]$Credential,
        [scriptblock]$Log
    )

    & $Log "=== $Computer ==="
    if ([string]::IsNullOrWhiteSpace($Computer)) {
        & $Log "ERRO - nome de computador vazio, pulando."
        return @{ Status = "ERRO"; Detail = "Nome de computador vazio" }
    }

    $pingOk = Test-Connection -ComputerName $Computer -Count 1 -Quiet -ErrorAction SilentlyContinue
    if (-not $pingOk) {
        & $Log "OFFLINE - a maquina nao respondeu ao ping."
        return @{ Status = "OFFLINE"; Detail = "Nao respondeu ping" }
    }

    $driveName = $null
    try {
        $driveName = New-RemoteDrive -Computer $Computer -Credential $Credential
        Copy-Item -Path $remoteScriptPath -Destination "${driveName}:\Windows\Temp\Upgrade-Edition.ps1" -Force -ErrorAction Stop
        & $Log "Script copiado para C:\Windows\Temp na maquina remota."

        $safeEditionId    = Remove-DangerousChars $EditionId
        $safeEditionLabel = Remove-DangerousChars $EditionLabel
        $safeKey          = Remove-DangerousChars $ProductKey

        $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"C:\Windows\Temp\Upgrade-Edition.ps1`" -TargetEditionId `"$safeEditionId`" -TargetEditionLabel `"$safeEditionLabel`" -ProductKey `"$safeKey`" -GraceDays $GraceDays"
        $proc = Invoke-WmiMethod -ComputerName $Computer -Credential $Credential -Class Win32_Process -Name Create -ArgumentList $cmd -ErrorAction Stop

        Remove-PSDrive -Name $driveName -ErrorAction SilentlyContinue
        $driveName = $null

        if ($proc.ReturnValue -ne 0) {
            & $Log "ERRO WMI - Win32_Process.Create retornou codigo $($proc.ReturnValue)"
            return @{ Status = "ERRO WMI"; Detail = "Codigo $($proc.ReturnValue)" }
        }

        & $Log "Processo disparado (PID remoto $($proc.ProcessId)). Aguardando o log aparecer..."
        $uncLog = "\\$Computer\C$\ProgramData\WinEditionTool\upgrade.log"
        $found = $false
        for ($wait = 0; $wait -lt 32; $wait += 4) {
            Start-Sleep -Seconds 4
            if (Test-Path $uncLog) { $found = $true; break }
        }

        if ($found) {
            $tail = Get-Content -Path $uncLog -Tail 10 -ErrorAction SilentlyContinue
            $tail | ForEach-Object { & $Log "    $_" }
            & $Log "OK - log lido com sucesso."
            return @{ Status = "OK"; Detail = ($tail -join " | ") }
        } else {
            & $Log "SEM LOG - processo disparou mas o log ainda nao apareceu apos 32s (pode precisar de mais tempo, ou o script falhou antes de logar)."
            return @{ Status = "SEM LOG"; Detail = "Log nao encontrado apos 32s" }
        }
    } catch {
        $msg = Get-FriendlyWmiError -RawMessage $_.Exception.Message -Computer $Computer
        & $Log "ERRO - $msg"
        return @{ Status = "ERRO"; Detail = $msg }
    } finally {
        if ($driveName) { try { Remove-PSDrive -Name $driveName -ErrorAction SilentlyContinue } catch {} }
    }
}

function Invoke-Win11Check {
    param(
        [string]$Computer,
        [System.Management.Automation.PSCredential]$Credential,
        [scriptblock]$Log
    )

    & $Log "=== $Computer ==="
    if ([string]::IsNullOrWhiteSpace($Computer)) {
        & $Log "ERRO - nome de computador vazio, pulando."
        return [PSCustomObject]@{ Computador=$Computer; Resultado="ERRO"; Detalhe="Nome de computador vazio" }
    }

    $pingOk = Test-Connection -ComputerName $Computer -Count 1 -Quiet -ErrorAction SilentlyContinue
    if (-not $pingOk) {
        & $Log "OFFLINE - a maquina nao respondeu ao ping."
        return [PSCustomObject]@{ Computador=$Computer; Resultado="OFFLINE"; Detalhe="Nao respondeu ping" }
    }

    $driveName = $null
    try {
        $driveName = New-RemoteDrive -Computer $Computer -Credential $Credential
        Copy-Item -Path $remoteCheckScriptPath -Destination "${driveName}:\Windows\Temp\Check-Win11-Eligibility.ps1" -Force -ErrorAction Stop
        & $Log "Script de checagem copiado para C:\Windows\Temp na maquina remota."

        $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"C:\Windows\Temp\Check-Win11-Eligibility.ps1`""
        $proc = Invoke-WmiMethod -ComputerName $Computer -Credential $Credential -Class Win32_Process -Name Create -ArgumentList $cmd -ErrorAction Stop

        Remove-PSDrive -Name $driveName -ErrorAction SilentlyContinue
        $driveName = $null

        if ($proc.ReturnValue -ne 0) {
            & $Log "ERRO WMI - Win32_Process.Create retornou codigo $($proc.ReturnValue)"
            return [PSCustomObject]@{ Computador=$Computer; Resultado="ERRO WMI"; Detalhe="Codigo $($proc.ReturnValue)" }
        }

        & $Log "Processo disparado (PID remoto $($proc.ProcessId)). Aguardando o resultado..."
        $uncCsv = "\\$Computer\C$\ProgramData\WinEditionTool\win11check.csv"
        $found = $false
        for ($wait = 0; $wait -lt 32; $wait += 4) {
            Start-Sleep -Seconds 4
            if (Test-Path $uncCsv) { $found = $true; break }
        }

        if ($found) {
            $row = Import-Csv -Path $uncCsv -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($row) {
                & $Log "    Sistema atual: $($row.SistemaAtual)"
                & $Log "    TPM2=$($row.TPM2)  SecureBoot=$($row.SecureBoot)  RAM=$($row.RAM_GB)GB  Disco livre=$($row.DiscoLivre_GB)GB"
                & $Log "    CPU: $($row.CPU) ($($row.Nucleos) nucleos)"
                & $Log "    Resultado: $($row.Resultado) - $($row.Detalhe)"
                $row.Computador = $Computer
                return $row
            } else {
                & $Log "ERRO - CSV de resultado veio vazio/corrompido."
                return [PSCustomObject]@{ Computador=$Computer; Resultado="ERRO"; Detalhe="CSV de resultado vazio ou corrompido" }
            }
        } else {
            & $Log "SEM RESULTADO - processo disparou mas o resultado ainda nao apareceu apos 32s."
            return [PSCustomObject]@{ Computador=$Computer; Resultado="SEM RESULTADO"; Detalhe="Resultado nao encontrado apos 32s" }
        }
    } catch {
        $msg = Get-FriendlyWmiError -RawMessage $_.Exception.Message -Computer $Computer
        & $Log "ERRO - $msg"
        return [PSCustomObject]@{ Computador=$Computer; Resultado="ERRO"; Detalhe=$msg }
    } finally {
        if ($driveName) { try { Remove-PSDrive -Name $driveName -ErrorAction SilentlyContinue } catch {} }
    }
}

function Invoke-Win11VersionUpgrade {
    # "Fire and forget": dispara o upgrade de versao (Win10 -> Win11) na
    # maquina remota e so espera uns 30s pra confirmar que COMECOU - nao
    # espera terminar (leva 30-90+ min e reinicia varias vezes sozinho).
    # Status retornado e "INICIADO", nao "OK" (que so o Invoke-EditionUpgrade
    # usa, pra troca de edicao que de fato conclui na hora).
    param(
        [string]$Computer,
        [string]$SetupSharePath,
        [bool]$SkipEligibilityCheck,
        [System.Management.Automation.PSCredential]$Credential,
        [scriptblock]$Log
    )

    & $Log "=== $Computer (upgrade de versao p/ Windows 11) ==="
    if ([string]::IsNullOrWhiteSpace($Computer)) {
        & $Log "ERRO - nome de computador vazio, pulando."
        return @{ Status = "ERRO"; Detail = "Nome de computador vazio" }
    }

    $pingOk = Test-Connection -ComputerName $Computer -Count 1 -Quiet -ErrorAction SilentlyContinue
    if (-not $pingOk) {
        & $Log "OFFLINE - a maquina nao respondeu ao ping."
        return @{ Status = "OFFLINE"; Detail = "Nao respondeu ping" }
    }

    $driveName = $null
    try {
        $driveName = New-RemoteDrive -Computer $Computer -Credential $Credential
        Copy-Item -Path $remoteUpgradeOSPath -Destination "${driveName}:\Windows\Temp\Upgrade-Win11-Versao.ps1" -Force -ErrorAction Stop
        & $Log "Script de upgrade copiado para C:\Windows\Temp na maquina remota."

        $safeShare = Remove-DangerousChars $SetupSharePath
        $skipFlag = if ($SkipEligibilityCheck) { " -SkipEligibilityCheck" } else { "" }
        $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"C:\Windows\Temp\Upgrade-Win11-Versao.ps1`" -SetupSharePath `"$safeShare`"$skipFlag"
        $proc = Invoke-WmiMethod -ComputerName $Computer -Credential $Credential -Class Win32_Process -Name Create -ArgumentList $cmd -ErrorAction Stop

        Remove-PSDrive -Name $driveName -ErrorAction SilentlyContinue
        $driveName = $null

        if ($proc.ReturnValue -ne 0) {
            & $Log "ERRO WMI - Win32_Process.Create retornou codigo $($proc.ReturnValue)"
            return @{ Status = "ERRO WMI"; Detail = "Codigo $($proc.ReturnValue)" }
        }

        & $Log "Processo disparado (PID remoto $($proc.ProcessId)). Aguardando confirmacao de inicio (ate 30s)..."
        $uncLog = "\\$Computer\C$\ProgramData\WinEditionTool\win11upgrade.log"
        $found = $false
        for ($wait = 0; $wait -lt 32; $wait += 4) {
            Start-Sleep -Seconds 4
            if (Test-Path $uncLog) { $found = $true; break }
        }

        if ($found) {
            $tail = Get-Content -Path $uncLog -Tail 6 -ErrorAction SilentlyContinue
            $tail | ForEach-Object { & $Log "    $_" }
            if ($tail -match "ja esta no Windows 11") {
                & $Log "JA_WINDOWS11 - nao precisava de upgrade de versao. Vou seguir so com a troca de edicao."
                return @{ Status = "JA_WINDOWS11"; Detail = ($tail -join " | ") }
            }
            if ($tail -match "ABORTADO|ERRO") {
                & $Log "ERRO/ABORTADO - confira o log acima."
                return @{ Status = "ERRO"; Detail = ($tail -join " | ") }
            }
            & $Log "INICIADO - upgrade disparado. Isso leva bastante tempo (30-90+ min) e reinicia a maquina sozinha. Use 'Verificar progresso' depois pra acompanhar."
            return @{ Status = "INICIADO"; Detail = ($tail -join " | ") }
        } else {
            & $Log "SEM LOG - processo disparou mas o log ainda nao apareceu apos 32s (a copia da midia pode estar demorando; confira 'Verificar progresso' daqui a pouco)."
            return @{ Status = "SEM LOG"; Detail = "Log nao encontrado apos 32s" }
        }
    } catch {
        $msg = Get-FriendlyWmiError -RawMessage $_.Exception.Message -Computer $Computer
        & $Log "ERRO - $msg"
        return @{ Status = "ERRO"; Detail = $msg }
    } finally {
        if ($driveName) { try { Remove-PSDrive -Name $driveName -ErrorAction SilentlyContinue } catch {} }
    }
}

function Get-Win11UpgradeProgress {
    # Le o log remoto de upgrade (sem disparar nada novo) pra acompanhar o
    # andamento de uma maquina que ja foi iniciada antes.
    param([string]$Computer, [scriptblock]$Log)
    & $Log "=== $Computer (progresso do upgrade) ==="
    $uncLog = "\\$Computer\C$\ProgramData\WinEditionTool\win11upgrade.log"
    if (-not (Test-Path $uncLog)) {
        & $Log "Nenhum log de upgrade encontrado nessa maquina ainda (ou ela nao esta acessivel agora)."
        return
    }
    $tail = Get-Content -Path $uncLog -Tail 15 -ErrorAction SilentlyContinue
    $tail | ForEach-Object { & $Log "    $_" }
    $os = $null
    try {
        $os = Get-CimInstance -ComputerName $Computer -ClassName Win32_OperatingSystem -ErrorAction Stop
    } catch {}
    if ($os) { & $Log "Sistema atual reportado agora via CIM: $($os.Caption)" }
}

function Invoke-LicenseCheck {
    param(
        [string]$Computer,
        [System.Management.Automation.PSCredential]$Credential,
        [scriptblock]$Log
    )

    & $Log "=== $Computer ==="
    if ([string]::IsNullOrWhiteSpace($Computer)) {
        & $Log "ERRO - nome de computador vazio, pulando."
        return [PSCustomObject]@{ Computador=$Computer; Resultado="ERRO"; Detalhe="Nome de computador vazio" }
    }

    $pingOk = Test-Connection -ComputerName $Computer -Count 1 -Quiet -ErrorAction SilentlyContinue
    if (-not $pingOk) {
        & $Log "OFFLINE - a maquina nao respondeu ao ping."
        return [PSCustomObject]@{ Computador=$Computer; Resultado="OFFLINE"; Detalhe="Nao respondeu ping" }
    }

    $driveName = $null
    try {
        $driveName = New-RemoteDrive -Computer $Computer -Credential $Credential
        Copy-Item -Path $remoteLicenseCheckPath -Destination "${driveName}:\Windows\Temp\Check-Licenca.ps1" -Force -ErrorAction Stop
        & $Log "Script de checagem de licenca copiado para C:\Windows\Temp na maquina remota."

        $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"C:\Windows\Temp\Check-Licenca.ps1`""
        $proc = Invoke-WmiMethod -ComputerName $Computer -Credential $Credential -Class Win32_Process -Name Create -ArgumentList $cmd -ErrorAction Stop

        Remove-PSDrive -Name $driveName -ErrorAction SilentlyContinue
        $driveName = $null

        if ($proc.ReturnValue -ne 0) {
            & $Log "ERRO WMI - Win32_Process.Create retornou codigo $($proc.ReturnValue)"
            return [PSCustomObject]@{ Computador=$Computer; Resultado="ERRO WMI"; Detalhe="Codigo $($proc.ReturnValue)" }
        }

        & $Log "Processo disparado (PID remoto $($proc.ProcessId)). Aguardando o resultado..."
        $uncCsv = "\\$Computer\C$\ProgramData\WinEditionTool\licencacheck.csv"
        $found = $false
        for ($wait = 0; $wait -lt 32; $wait += 4) {
            Start-Sleep -Seconds 4
            if (Test-Path $uncCsv) { $found = $true; break }
        }

        if ($found) {
            $row = Import-Csv -Path $uncCsv -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($row) {
                & $Log "    Sistema: $($row.SistemaAtual) | Edicao: $($row.EditionID) | Resultado: $($row.Resultado)"
                $row.Computador = $Computer
                return $row
            } else {
                & $Log "ERRO - CSV de resultado veio vazio/corrompido."
                return [PSCustomObject]@{ Computador=$Computer; Resultado="ERRO"; Detalhe="CSV de resultado vazio ou corrompido" }
            }
        } else {
            & $Log "SEM RESULTADO - processo disparou mas o resultado ainda nao apareceu apos 32s."
            return [PSCustomObject]@{ Computador=$Computer; Resultado="SEM RESULTADO"; Detalhe="Resultado nao encontrado apos 32s" }
        }
    } catch {
        $msg = Get-FriendlyWmiError -RawMessage $_.Exception.Message -Computer $Computer
        & $Log "ERRO - $msg"
        return [PSCustomObject]@{ Computador=$Computer; Resultado="ERRO"; Detalhe=$msg }
    } finally {
        if ($driveName) { try { Remove-PSDrive -Name $driveName -ErrorAction SilentlyContinue } catch {} }
    }
}

# ---------------------------------------------------------------------------
# 3. Interface grafica
# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "WinEditionTool"
$form.Size = New-Object System.Drawing.Size(600, 860)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

# --- credencial: compartilhada pelas duas abas (ambas mexem em maquina remota) ---
$pnlCred = New-Object System.Windows.Forms.Panel
$pnlCred.Location = New-Object System.Drawing.Point(0, 0)
$pnlCred.Size = New-Object System.Drawing.Size(584, 44)
$pnlCred.BorderStyle = "FixedSingle"
$form.Controls.Add($pnlCred)

$btnCred = New-Object System.Windows.Forms.Button
$btnCred.Text = "Definir credencial de administrador..."
$btnCred.Location = New-Object System.Drawing.Point(10, 8)
$btnCred.Size = New-Object System.Drawing.Size(260, 28)
$pnlCred.Controls.Add($btnCred)

$lblCred = New-Object System.Windows.Forms.Label
$lblCred.Text = "nenhuma credencial definida"
$lblCred.Location = New-Object System.Drawing.Point(280, 15)
$lblCred.AutoSize = $true
$lblCred.ForeColor = [System.Drawing.Color]::DarkRed
$pnlCred.Controls.Add($lblCred)

$btnCred.Add_Click({
    $script:cred = Get-Credential -Message "Conta com permissao de administrador local na(s) estacao(oes) de destino (ex: DOMINIO\usuario)"
    if ($script:cred) {
        $lblCred.Text = "credencial definida: $($script:cred.UserName)"
        $lblCred.ForeColor = [System.Drawing.Color]::DarkGreen
    } else {
        # usuario clicou Cancelar na caixa de login - garante que o rotulo
        # nao fique mostrando uma credencial antiga que ja nao existe mais
        $lblCred.Text = "nenhuma credencial definida"
        $lblCred.ForeColor = [System.Drawing.Color]::DarkRed
    }
})

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(0, 48)
$tabs.Size = New-Object System.Drawing.Size(584, 770)
$form.Controls.Add($tabs)

$tabEdition = New-Object System.Windows.Forms.TabPage
$tabEdition.Text = "Trocar edicao"
$tabs.Controls.Add($tabEdition)

$tabCheck = New-Object System.Windows.Forms.TabPage
$tabCheck.Text = "Elegibilidade Windows 11"
$tabs.Controls.Add($tabCheck)

$tabLicense = New-Object System.Windows.Forms.TabPage
$tabLicense.Text = "Verificar licenciamento"
$tabs.Controls.Add($tabLicense)

function Add-LabelTo($parent, $text, $x, $y) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $text
    $lbl.Location = New-Object System.Drawing.Point($x, $y)
    $lbl.AutoSize = $true
    $parent.Controls.Add($lbl)
    return $lbl
}

# Componente reutilizavel: caixa multi-linha de computadores + "Carregar CSV..."
function New-ComputerListBox {
    param($Parent, [int]$X, [int]$Y)

    Add-LabelTo $Parent "Computador(es) - um nome/IP por linha, ou carregue um CSV:" $X $Y | Out-Null
    $Y += 20

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point($X, $Y)
    $txt.Size = New-Object System.Drawing.Size(410, 70)
    $txt.Multiline = $true
    $txt.ScrollBars = "Vertical"
    $txt.Font = New-Object System.Drawing.Font("Consolas", 9)
    $Parent.Controls.Add($txt)

    $btnCsv = New-Object System.Windows.Forms.Button
    $btnCsv.Text = "Carregar CSV..."
    $btnCsv.Location = New-Object System.Drawing.Point(($X + 417), $Y)
    $btnCsv.Size = New-Object System.Drawing.Size(103, 32)
    $Parent.Controls.Add($btnCsv)

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Text = ""
    $lblCount.Location = New-Object System.Drawing.Point(($X + 417), ($Y + 38))
    $lblCount.AutoSize = $true
    $lblCount.ForeColor = [System.Drawing.Color]::FromArgb(124,138,131)
    $Parent.Controls.Add($lblCount)

    $getList = {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $result = New-Object System.Collections.Generic.List[string]
        $txt.Text -split "[\r\n,;]+" | ForEach-Object {
            $name = $_.Trim()
            if ($name -and ($name -notmatch '^(computador|computer|nome|hostname)$') -and $seen.Add($name)) {
                $result.Add($name)
            }
        }
        return $result
    }.GetNewClosure()

    $updateCount = {
        $n = @(& $getList).Count
        $lblCount.Text = if ($n -eq 1) { "1 maquina" } else { "$n maquinas" }
    }.GetNewClosure()

    $txt.Add_TextChanged($updateCount)

    $btnCsv.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = "CSV (*.csv)|*.csv|Todos os arquivos (*.*)|*.*"
        $dlg.Title = "Selecionar CSV com a lista de maquinas"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            try {
                $raw = Get-Content -Path $dlg.FileName -ErrorAction Stop
                $names = $raw | ForEach-Object { ($_ -split ",")[0].Trim().Trim('"') } |
                         Where-Object { $_ -and ($_ -notmatch '^(computador|computer|nome|hostname)$') }
                $existing = & $getList
                $seen2 = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                $merged = New-Object System.Collections.Generic.List[string]
                foreach ($n in ($existing + $names)) {
                    $n = $n.Trim()
                    if ($n -and $seen2.Add($n)) { $merged.Add($n) }
                }
                $txt.Text = ($merged -join [Environment]::NewLine)
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Nao consegui ler o arquivo: $($_.Exception.Message)","Erro ao carregar CSV",'OK','Error') | Out-Null
            }
        }
    }.GetNewClosure())

    & $updateCount

    return [PSCustomObject]@{
        TextBox    = $txt
        CsvButton  = $btnCsv
        NextY      = ($Y + 78)
        GetList    = $getList
    }
}

# =========================== ABA 1 - TROCAR EDICAO =========================
$y = 12
$listWidget1 = New-ComputerListBox -Parent $tabEdition -X 12 -Y $y
$txtComputer = $listWidget1.TextBox
$btnLoadCsv  = $listWidget1.CsvButton
$GetComputerList = $listWidget1.GetList
$y = $listWidget1.NextY

Add-LabelTo $tabEdition "Edicao de destino:" 12 $y | Out-Null
$y += 20
$cmbEdition = New-Object System.Windows.Forms.ComboBox
$cmbEdition.Location = New-Object System.Drawing.Point(12, $y)
$cmbEdition.Size = New-Object System.Drawing.Size(250, 22)
$cmbEdition.DropDownStyle = "DropDownList"
@("Education","Pro Education","Enterprise","Pro","Pro for Workstations","Outra (digitar abaixo)") | ForEach-Object { $cmbEdition.Items.Add($_) | Out-Null }
$cmbEdition.SelectedIndex = 0
$tabEdition.Controls.Add($cmbEdition)

$txtEditionCustom = New-Object System.Windows.Forms.TextBox
$txtEditionCustom.Location = New-Object System.Drawing.Point(277, $y)
$txtEditionCustom.Size = New-Object System.Drawing.Size(255, 22)
$txtEditionCustom.Enabled = $false
$txtEditionCustom.Text = "(EditionID exato, ex: ServerStandard)"
$tabEdition.Controls.Add($txtEditionCustom)
$cmbEdition.Add_SelectedIndexChanged({
    $txtEditionCustom.Enabled = ($cmbEdition.SelectedItem -eq "Outra (digitar abaixo)")
})
$y += 34

# nomes amigaveis do combo -> EditionID real do Windows (o que fica gravado
# em HKLM:\...\CurrentVersion -> EditionID). A comparacao no script remoto e
# exata, entao isso precisa bater certinho com o valor real do Windows.
$script:editionIdMap = @{
    "Education"             = "Education"
    "Pro Education"         = "ProfessionalEducation"
    "Enterprise"            = "Enterprise"
    "Pro"                   = "Professional"
    "Pro for Workstations"  = "ProfessionalWorkstation"
}

Add-LabelTo $tabEdition "Versao do Windows (alem da edicao acima):" 12 $y | Out-Null
$y += 20
$cmbVersion = New-Object System.Windows.Forms.ComboBox
$cmbVersion.Location = New-Object System.Drawing.Point(12, $y)
$cmbVersion.Size = New-Object System.Drawing.Size(340, 22)
$cmbVersion.DropDownStyle = "DropDownList"
@("Manter a versao atual (so trocar edicao)","Windows 11 (fazer upgrade de versao se a maquina ainda for Windows 10)") | ForEach-Object { $cmbVersion.Items.Add($_) | Out-Null }
$cmbVersion.SelectedIndex = 0
$tabEdition.Controls.Add($cmbVersion)
$y += 30

$lblShare = Add-LabelTo $tabEdition "Midia de instalacao do Windows 11 (caminho de rede, ex: \\servidor\Win11):" 12 $y
$lblShare.Enabled = $false
$y += 20
$txtWin11Share = New-Object System.Windows.Forms.TextBox
$txtWin11Share.Location = New-Object System.Drawing.Point(12, $y)
$txtWin11Share.Size = New-Object System.Drawing.Size(400, 22)
$txtWin11Share.Enabled = $false
$tabEdition.Controls.Add($txtWin11Share)

$chkSkipElig = New-Object System.Windows.Forms.CheckBox
$chkSkipElig.Text = "Pular checagem de elegibilidade"
$chkSkipElig.Location = New-Object System.Drawing.Point(420, ($y + 2))
$chkSkipElig.Size = New-Object System.Drawing.Size(115, 40)
$chkSkipElig.Enabled = $false
$tabEdition.Controls.Add($chkSkipElig)
$y += 30

$cmbVersion.Add_SelectedIndexChanged({
    $wantsWin11 = $cmbVersion.SelectedIndex -eq 1
    $lblShare.Enabled = $wantsWin11
    $txtWin11Share.Enabled = $wantsWin11
    $chkSkipElig.Enabled = $wantsWin11
})

$lblWin11Note = New-Object System.Windows.Forms.Label
$lblWin11Note.Text = "Atencao: o upgrade de versao demora 30-90+ min por maquina e reinicia sozinha varias vezes.`r`nA troca de edicao (chave abaixo) continua sendo aplicada normalmente nas maquinas que ja`r`nestiverem no Windows 11 (ou que ja nao precisem de upgrade)."
$lblWin11Note.Location = New-Object System.Drawing.Point(12, $y)
$lblWin11Note.Size = New-Object System.Drawing.Size(548, 42)
$lblWin11Note.ForeColor = [System.Drawing.Color]::FromArgb(140,90,20)
$tabEdition.Controls.Add($lblWin11Note)
$y += 48

Add-LabelTo $tabEdition "Chave de produto (Product Key):" 12 $y | Out-Null
$y += 20
$txtKey = New-Object System.Windows.Forms.TextBox
$txtKey.Location = New-Object System.Drawing.Point(12, $y)
$txtKey.Size = New-Object System.Drawing.Size(520, 22)
$txtKey.CharacterCasing = "Upper"
$tabEdition.Controls.Add($txtKey)
$y += 34

Add-LabelTo $tabEdition "Dias de tolerancia antes do reinicio forcado:" 12 $y | Out-Null
$y += 20
$numDays = New-Object System.Windows.Forms.NumericUpDown
$numDays.Location = New-Object System.Drawing.Point(12, $y)
$numDays.Size = New-Object System.Drawing.Size(60, 22)
$numDays.Minimum = 0
$numDays.Maximum = 14
$numDays.Value = 3
$tabEdition.Controls.Add($numDays)
$y += 42

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = "Aplicar"
$btnRun.Location = New-Object System.Drawing.Point(12, $y)
$btnRun.Size = New-Object System.Drawing.Size(260, 32)
$btnRun.BackColor = [System.Drawing.Color]::FromArgb(12,110,143)
$btnRun.ForeColor = [System.Drawing.Color]::White
$tabEdition.Controls.Add($btnRun)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = ""
$lblStatus.Location = New-Object System.Drawing.Point(282, ($y + 8))
$lblStatus.AutoSize = $true
$lblStatus.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$tabEdition.Controls.Add($lblStatus)
$y += 42

$btnProgress = New-Object System.Windows.Forms.Button
$btnProgress.Text = "Verificar progresso do upgrade Win11 (maquinas acima)"
$btnProgress.Location = New-Object System.Drawing.Point(12, $y)
$btnProgress.Size = New-Object System.Drawing.Size(340, 26)
$tabEdition.Controls.Add($btnProgress)
$btnProgress.Add_Click({
    $computers = @(& $GetComputerList)
    if ($computers.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("Informe pelo menos um computador na caixa acima para verificar o progresso.","Campo obrigatorio",'OK','Warning') | Out-Null; return }
    Set-FormBusy $true
    foreach ($c in $computers) { Get-Win11UpgradeProgress -Computer $c -Log { param($t) Add-LogLine $t }; Add-LogLine "" }
    Set-FormBusy $false
})
$y += 36

Add-LabelTo $tabEdition "Log:" 12 $y | Out-Null
$y += 20
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(12, $y)
$txtLog.Size = New-Object System.Drawing.Size(548, 240)
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$txtLog.BackColor = [System.Drawing.Color]::White
$tabEdition.Controls.Add($txtLog)

function Add-LogLine([string]$text) {
    $txtLog.AppendText("$text`r`n")
    $txtLog.SelectionStart = $txtLog.Text.Length
    $txtLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-FormBusy([bool]$busy) {
    $btnRun.Enabled       = -not $busy
    $btnLoadCsv.Enabled   = -not $busy
    $txtComputer.Enabled  = -not $busy
    $cmbEdition.Enabled   = -not $busy
    $txtEditionCustom.Enabled = (-not $busy) -and ($cmbEdition.SelectedItem -eq "Outra (digitar abaixo)")
    $cmbVersion.Enabled   = -not $busy
    $txtWin11Share.Enabled = (-not $busy) -and ($cmbVersion.SelectedIndex -eq 1)
    $chkSkipElig.Enabled  = (-not $busy) -and ($cmbVersion.SelectedIndex -eq 1)
    $txtKey.Enabled       = -not $busy
    $numDays.Enabled      = -not $busy
    $btnCred.Enabled      = -not $busy
    $btnCheck.Enabled     = -not $busy
    $txtComputer2.Enabled = -not $busy
    $btnLoadCsv2.Enabled  = -not $busy
    $btnRun.Enabled       = -not $busy
    if ($btnLicenseCheck) { $btnLicenseCheck.Enabled = -not $busy }
    if ($txtComputer3)    { $txtComputer3.Enabled = -not $busy }
    if ($btnLoadCsv3)     { $btnLoadCsv3.Enabled = -not $busy }
    if ($btnProgress)     { $btnProgress.Enabled = -not $busy }
}

$btnRun.Add_Click({
    $computers = @(& $GetComputerList)

    if ($cmbEdition.SelectedItem -eq "Outra (digitar abaixo)") {
        $customText = $txtEditionCustom.Text.Trim()
        if (-not $customText -or $customText -eq "(EditionID exato, ex: ServerStandard)") {
            [System.Windows.Forms.MessageBox]::Show("Digite o EditionID exato da edicao no campo ao lado do combo (ex: Enterprise, Education, ServerStandard).","Edicao invalida",'OK','Warning') | Out-Null
            return
        }
        $editionId = $customText
        $editionLabel = $customText
    } else {
        $editionLabel = $cmbEdition.SelectedItem.ToString()
        $editionId = $script:editionIdMap[$editionLabel]
    }

    $key = $txtKey.Text.Trim()
    $days = [int]$numDays.Value
    $wantsWin11 = $cmbVersion.SelectedIndex -eq 1
    $win11Share = $txtWin11Share.Text.Trim()
    $skipElig = $chkSkipElig.Checked

    if ($computers.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("Informe pelo menos um computador (um por linha) ou carregue um CSV.","Campo obrigatorio",'OK','Warning') | Out-Null; return }
    if (-not $key) { [System.Windows.Forms.MessageBox]::Show("Informe a chave de produto.","Campo obrigatorio",'OK','Warning') | Out-Null; return }
    if (-not $script:cred) { [System.Windows.Forms.MessageBox]::Show("Defina a credencial de administrador antes de aplicar.","Credencial necessaria",'OK','Warning') | Out-Null; return }
    if ($wantsWin11 -and -not $win11Share) { [System.Windows.Forms.MessageBox]::Show("Voce escolheu 'Windows 11' na versao - informe o caminho de rede da midia de instalacao (ex: \\servidor\Win11).","Campo obrigatorio",'OK','Warning') | Out-Null; return }

    if ($computers.Count -gt 1) {
        $confirm = [System.Windows.Forms.MessageBox]::Show("Confirma processar $($computers.Count) maquinas com a edicao '$editionLabel'?","Confirmar lote",'YesNo','Question')
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    if ($wantsWin11) {
        $confirmW11 = [System.Windows.Forms.MessageBox]::Show("Voce escolheu upgrade de versao para Windows 11. Maquinas ainda no Windows 10 vao iniciar um processo longo (30-90+ min, com reinicios automaticos) e SO a troca de edicao sera aplicada nelas depois de concluido (rode de novo mais tarde). Confirma?","Confirmar upgrade de versao",'YesNo','Warning')
        if ($confirmW11 -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    if ($days -eq 0) {
        $confirm0 = [System.Windows.Forms.MessageBox]::Show("Tolerancia de 0 dias significa que o reinicio forcado pode ser cobrado quase imediatamente apos a chave ser aplicada. Confirma mesmo assim?","Confirmar tolerancia 0",'YesNo','Warning')
        if ($confirm0 -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    $txtLog.Clear()
    Set-FormBusy $true
    $counts = @{ OK = 0; OFFLINE = 0; OUTRO = 0 }
    $loteResults = New-Object System.Collections.Generic.List[object]

    for ($i = 0; $i -lt $computers.Count; $i++) {
        $computer = $computers[$i]
        $lblStatus.Text = "Processando $($i+1) de $($computers.Count): $computer"
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
        [System.Windows.Forms.Application]::DoEvents()

        if ($wantsWin11) {
            $upResult = Invoke-Win11VersionUpgrade -Computer $computer -SetupSharePath $win11Share -SkipEligibilityCheck $skipElig -Credential $script:cred -Log { param($t) Add-LogLine $t }
            $upLine = "{0},{1},{2},{3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), ($computer -replace ",",";"), $upResult.Status, ($upResult.Detail -replace ",",";")
            Write-HistoryLine -Path $historyUpgradePath -Line $upLine | Out-Null

            if ($upResult.Status -ne "JA_WINDOWS11") {
                # Upgrade de versao disparado (ou deu erro/offline) - a troca de
                # edicao fica pendente pra depois, quando a maquina ja estiver
                # no Windows 11 (nao faz sentido aplicar slmgr no meio do upgrade).
                $loteResults.Add([PSCustomObject]@{ Computador = $computer; Status = "UPGRADE_" + $upResult.Status; Detalhe = $upResult.Detail; Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") })
                if ($upResult.Status -eq "OFFLINE") { $counts.OFFLINE++ } else { $counts.OUTRO++ }
                Add-LogLine ""
                continue
            }
            # JA_WINDOWS11: cai direto pra troca de edicao normal abaixo.
        }

        $result = Invoke-EditionUpgrade -Computer $computer -EditionId $editionId -EditionLabel $editionLabel -ProductKey $key -GraceDays $days -Credential $script:cred -Log { param($t) Add-LogLine $t }

        $line = "{0},{1},{2},{3},{4}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), ($computer -replace ",",";"), ($editionLabel -replace ",",";"), $result.Status, ($result.Detail -replace ",",";")
        if (-not (Write-HistoryLine -Path $historyPath -Line $line)) {
            Add-LogLine "  (aviso: nao consegui gravar esta linha em historico.csv - provavelmente esta aberto em outro programa. Linha salva em historico.csv.pendentes)"
        }
        $loteResults.Add([PSCustomObject]@{ Computador = $computer; Status = $result.Status; Detalhe = $result.Detail; Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") })

        if ($result.Status -eq "OK") { $counts.OK++ }
        elseif ($result.Status -eq "OFFLINE") { $counts.OFFLINE++ }
        else { $counts.OUTRO++ }

        Add-LogLine ""
    }

    if ($computers.Count -gt 1) {
        $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $lotePath = Join-Path $filesDir "resultado_lote_$stamp.csv"
        $loteResults | Export-Csv -Path $lotePath -NoTypeInformation -Encoding UTF8
        Add-LogLine "Relatorio deste lote salvo em: $lotePath"
    }

    $summary = "OK: $($counts.OK)  |  Offline: $($counts.OFFLINE)  |  Outros: $($counts.OUTRO)"
    $lblStatus.Text = "Concluido - $summary"
    $lblStatus.ForeColor = if ($counts.OUTRO -gt 0) { [System.Drawing.Color]::DarkRed }
                           elseif ($counts.OFFLINE -gt 0) { [System.Drawing.Color]::DarkOrange }
                           else { [System.Drawing.Color]::DarkGreen }
    Set-FormBusy $false

    $txtKey.Text = ""
    $script:cred = $null
    $lblCred.Text = "nenhuma credencial definida"
    $lblCred.ForeColor = [System.Drawing.Color]::DarkRed
    Add-LogLine "(chave de produto e credencial limpas da memoria - informe novamente para o proximo lote)"
})

# ======================= ABA 2 - ELEGIBILIDADE WINDOWS 11 ==================
$y2 = 12
$listWidget2 = New-ComputerListBox -Parent $tabCheck -X 12 -Y $y2
$txtComputer2 = $listWidget2.TextBox
$btnLoadCsv2  = $listWidget2.CsvButton
$GetComputerList2 = $listWidget2.GetList
$y2 = $listWidget2.NextY

$noteCheck = New-Object System.Windows.Forms.Label
$noteCheck.Text = "Verifica TPM 2.0, Secure Boot/UEFI, RAM, espaco em disco e requisitos basicos de CPU.`r`nSo verifica - nao instala nem altera nada na maquina. O modelo exato do processador`r`nfica no relatorio, pra conferir manualmente contra a lista oficial da Microsoft se precisar."
$noteCheck.Location = New-Object System.Drawing.Point(12, $y2)
$noteCheck.Size = New-Object System.Drawing.Size(548, 48)
$noteCheck.ForeColor = [System.Drawing.Color]::FromArgb(75,91,84)
$tabCheck.Controls.Add($noteCheck)
$y2 += 54

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = "Verificar elegibilidade"
$btnCheck.Location = New-Object System.Drawing.Point(12, $y2)
$btnCheck.Size = New-Object System.Drawing.Size(260, 32)
$btnCheck.BackColor = [System.Drawing.Color]::FromArgb(12,110,143)
$btnCheck.ForeColor = [System.Drawing.Color]::White
$tabCheck.Controls.Add($btnCheck)

$lblStatus2 = New-Object System.Windows.Forms.Label
$lblStatus2.Text = ""
$lblStatus2.Location = New-Object System.Drawing.Point(282, ($y2 + 8))
$lblStatus2.AutoSize = $true
$lblStatus2.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$tabCheck.Controls.Add($lblStatus2)
$y2 += 42

Add-LabelTo $tabCheck "Log:" 12 $y2 | Out-Null
$y2 += 20
$txtLog2 = New-Object System.Windows.Forms.TextBox
$txtLog2.Location = New-Object System.Drawing.Point(12, $y2)
$txtLog2.Size = New-Object System.Drawing.Size(548, 300)
$txtLog2.Multiline = $true
$txtLog2.ScrollBars = "Vertical"
$txtLog2.ReadOnly = $true
$txtLog2.Font = New-Object System.Drawing.Font("Consolas", 9)
$txtLog2.BackColor = [System.Drawing.Color]::White
$tabCheck.Controls.Add($txtLog2)

function Add-LogLine2([string]$text) {
    $txtLog2.AppendText("$text`r`n")
    $txtLog2.SelectionStart = $txtLog2.Text.Length
    $txtLog2.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

$btnCheck.Add_Click({
    $computers = @(& $GetComputerList2)
    if ($computers.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("Informe pelo menos um computador (um por linha) ou carregue um CSV.","Campo obrigatorio",'OK','Warning') | Out-Null; return }
    if (-not $script:cred) { [System.Windows.Forms.MessageBox]::Show("Defina a credencial de administrador antes de verificar.","Credencial necessaria",'OK','Warning') | Out-Null; return }

    if ($computers.Count -gt 1) {
        $confirm = [System.Windows.Forms.MessageBox]::Show("Confirma verificar $($computers.Count) maquinas?","Confirmar verificacao",'YesNo','Question')
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    $txtLog2.Clear()
    Set-FormBusy $true
    $counts = @{ ELEGIVEL = 0; NAO = 0; JA11 = 0; OFFLINE = 0; OUTRO = 0 }
    $results = New-Object System.Collections.Generic.List[object]

    for ($i = 0; $i -lt $computers.Count; $i++) {
        $computer = $computers[$i]
        $lblStatus2.Text = "Verificando $($i+1) de $($computers.Count): $computer"
        $lblStatus2.ForeColor = [System.Drawing.Color]::DarkOrange
        [System.Windows.Forms.Application]::DoEvents()

        $row = Invoke-Win11Check -Computer $computer -Credential $script:cred -Log { param($t) Add-LogLine2 $t }
        $results.Add($row)

        $line = "{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10}" -f `
            (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), ($computer -replace ",",";"), $row.SistemaAtual, $row.TPM2, $row.SecureBoot, `
            $row.RAM_GB, $row.DiscoLivre_GB, ($row.CPU -replace ",",";"), $row.Nucleos, $row.Resultado, ($row.Detalhe -replace ",",";")
        if (-not (Write-HistoryLine -Path $historyCheckPath -Line $line)) {
            Add-LogLine2 "  (aviso: nao consegui gravar esta linha em historico_elegibilidade.csv - provavelmente esta aberto em outro programa. Linha salva em historico_elegibilidade.csv.pendentes)"
        }

        switch ($row.Resultado) {
            "PROVAVEL_ELEGIVEL" { $counts.ELEGIVEL++ }
            "JA_WINDOWS11"      { $counts.JA11++ }
            "OFFLINE"           { $counts.OFFLINE++ }
            "NAO_ELEGIVEL"      { $counts.NAO++ }
            default             { $counts.OUTRO++ }
        }
        Add-LogLine2 ""
    }

    if ($computers.Count -gt 1) {
        $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $lotePath = Join-Path $filesDir "elegibilidade_win11_$stamp.csv"
        $results | Export-Csv -Path $lotePath -NoTypeInformation -Encoding UTF8
        Add-LogLine2 "Relatorio desta verificacao salvo em: $lotePath"
    }

    $summary = "Elegivel: $($counts.ELEGIVEL)  |  Ja e Win11: $($counts.JA11)  |  Nao elegivel: $($counts.NAO)  |  Offline: $($counts.OFFLINE)  |  Outros: $($counts.OUTRO)"
    $lblStatus2.Text = "Concluido - $summary"
    $lblStatus2.ForeColor = if ($counts.NAO -gt 0 -or $counts.OUTRO -gt 0) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::DarkGreen }
    Set-FormBusy $false

    $script:cred = $null
    $lblCred.Text = "nenhuma credencial definida"
    $lblCred.ForeColor = [System.Drawing.Color]::DarkRed
    Add-LogLine2 "(credencial limpa da memoria - informe novamente para a proxima verificacao)"
})

# ======================= ABA 3 - VERIFICAR LICENCIAMENTO ===================
$y3 = 12
$listWidget3 = New-ComputerListBox -Parent $tabLicense -X 12 -Y $y3
$txtComputer3 = $listWidget3.TextBox
$btnLoadCsv3  = $listWidget3.CsvButton
$GetComputerList3 = $listWidget3.GetList
$y3 = $listWidget3.NextY

$noteLicense = New-Object System.Windows.Forms.Label
$noteLicense.Text = "Roda 'slmgr /dli' em cada maquina pra saber se esta ativada ou mostrando`r`n'Ative o Windows'. So verifica - nao muda nada. Util pra levantar em lote quais`r`nmaquinas do OCS (ou de qualquer lista) estao sem licenca valida."
$noteLicense.Location = New-Object System.Drawing.Point(12, $y3)
$noteLicense.Size = New-Object System.Drawing.Size(548, 48)
$noteLicense.ForeColor = [System.Drawing.Color]::FromArgb(75,91,84)
$tabLicense.Controls.Add($noteLicense)
$y3 += 54

$btnLicenseCheck = New-Object System.Windows.Forms.Button
$btnLicenseCheck.Text = "Verificar licenciamento"
$btnLicenseCheck.Location = New-Object System.Drawing.Point(12, $y3)
$btnLicenseCheck.Size = New-Object System.Drawing.Size(260, 32)
$btnLicenseCheck.BackColor = [System.Drawing.Color]::FromArgb(12,110,143)
$btnLicenseCheck.ForeColor = [System.Drawing.Color]::White
$tabLicense.Controls.Add($btnLicenseCheck)

$lblStatus3 = New-Object System.Windows.Forms.Label
$lblStatus3.Text = ""
$lblStatus3.Location = New-Object System.Drawing.Point(282, ($y3 + 8))
$lblStatus3.AutoSize = $true
$lblStatus3.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$tabLicense.Controls.Add($lblStatus3)
$y3 += 42

Add-LabelTo $tabLicense "Log:" 12 $y3 | Out-Null
$y3 += 20
$txtLog3 = New-Object System.Windows.Forms.TextBox
$txtLog3.Location = New-Object System.Drawing.Point(12, $y3)
$txtLog3.Size = New-Object System.Drawing.Size(548, 300)
$txtLog3.Multiline = $true
$txtLog3.ScrollBars = "Vertical"
$txtLog3.ReadOnly = $true
$txtLog3.Font = New-Object System.Drawing.Font("Consolas", 9)
$txtLog3.BackColor = [System.Drawing.Color]::White
$tabLicense.Controls.Add($txtLog3)

function Add-LogLine3([string]$text) {
    $txtLog3.AppendText("$text`r`n")
    $txtLog3.SelectionStart = $txtLog3.Text.Length
    $txtLog3.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

$btnLicenseCheck.Add_Click({
    $computers = @(& $GetComputerList3)
    if ($computers.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("Informe pelo menos um computador (um por linha) ou carregue um CSV.","Campo obrigatorio",'OK','Warning') | Out-Null; return }
    if (-not $script:cred) { [System.Windows.Forms.MessageBox]::Show("Defina a credencial de administrador antes de verificar.","Credencial necessaria",'OK','Warning') | Out-Null; return }

    if ($computers.Count -gt 1) {
        $confirm = [System.Windows.Forms.MessageBox]::Show("Confirma verificar o licenciamento de $($computers.Count) maquinas?","Confirmar verificacao",'YesNo','Question')
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    $txtLog3.Clear()
    Set-FormBusy $true
    $counts = @{ ATIVADO = 0; NAO_ATIVADO = 0; OFFLINE = 0; OUTRO = 0 }
    $results = New-Object System.Collections.Generic.List[object]
    $semLicenca = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt $computers.Count; $i++) {
        $computer = $computers[$i]
        $lblStatus3.Text = "Verificando $($i+1) de $($computers.Count): $computer"
        $lblStatus3.ForeColor = [System.Drawing.Color]::DarkOrange
        [System.Windows.Forms.Application]::DoEvents()

        $row = Invoke-LicenseCheck -Computer $computer -Credential $script:cred -Log { param($t) Add-LogLine3 $t }
        $results.Add($row)

        $line = "{0},{1},{2},{3},{4},{5},{6}" -f `
            (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), ($computer -replace ",",";"), $row.SistemaAtual, $row.EditionID, $row.Ativado, $row.Resultado, ($row.Detalhe -replace ",",";")
        if (-not (Write-HistoryLine -Path $historyLicensePath -Line $line)) {
            Add-LogLine3 "  (aviso: nao consegui gravar esta linha em historico_licenca.csv - provavelmente esta aberto em outro programa. Linha salva em historico_licenca.csv.pendentes)"
        }

        switch ($row.Resultado) {
            "ATIVADO"     { $counts.ATIVADO++ }
            "NAO_ATIVADO" { $counts.NAO_ATIVADO++; $semLicenca.Add($computer) }
            "OFFLINE"     { $counts.OFFLINE++ }
            default       { $counts.OUTRO++ }
        }
        Add-LogLine3 ""
    }

    if ($computers.Count -gt 1) {
        $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $lotePath = Join-Path $filesDir "licenciamento_$stamp.csv"
        $results | Export-Csv -Path $lotePath -NoTypeInformation -Encoding UTF8
        Add-LogLine3 "Relatorio desta verificacao salvo em: $lotePath"
    }

    if ($semLicenca.Count -gt 0) {
        Add-LogLine3 ""
        Add-LogLine3 "=== MAQUINAS SEM LICENCA VALIDA (precisam reaplicar a chave / reiniciar) ==="
        $semLicenca | ForEach-Object { Add-LogLine3 "  $_" }
    }

    $summary = "Ativado: $($counts.ATIVADO)  |  NAO ativado: $($counts.NAO_ATIVADO)  |  Offline: $($counts.OFFLINE)  |  Outros: $($counts.OUTRO)"
    $lblStatus3.Text = "Concluido - $summary"
    $lblStatus3.ForeColor = if ($counts.NAO_ATIVADO -gt 0 -or $counts.OUTRO -gt 0) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::DarkGreen }
    Set-FormBusy $false

    $script:cred = $null
    $lblCred.Text = "nenhuma credencial definida"
    $lblCred.ForeColor = [System.Drawing.Color]::DarkRed
    Add-LogLine3 "(credencial limpa da memoria - informe novamente para a proxima verificacao)"
})

Add-LogLine "WinEditionTool pronto. Pasta de trabalho: $filesDir"
Add-LogLine "Cole um ou mais nomes/IPs de computador (um por linha) ou carregue um CSV, preencha os demais campos e clique em 'Aplicar'."
Add-LogLine2 "Pronto para verificar elegibilidade para Windows 11."
Add-LogLine3 "Pronto para verificar licenciamento. Cole uma lista de maquinas (ou toda a base) e clique em 'Verificar licenciamento'."

[System.Windows.Forms.Application]::EnableVisualStyles()
$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
