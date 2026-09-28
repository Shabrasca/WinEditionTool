# Arquitetura

## Visão geral

`src/WinEditionTool.ps1` é um único script PowerShell que contém:

1. **A GUI** (Windows Forms) com três abas: "Trocar edição", "Elegibilidade
   Windows 11" e "Verificar licenciamento".
2. **Os scripts que rodam na máquina remota**, embutidos como here-strings
   (`$remoteScriptContent`, `$remoteCheckScriptContent`,
   `$remoteWin11UpgradeContent`, `$remoteLicenseCheckContent`). Na primeira
   execução, cada bloco é escrito em disco dentro de
   `WinEditionTool-Files\`, ao lado do executável.

## Fluxo de execução remota

```
[Máquina de gestão]                         [Máquina remota]
      |                                            |
      |  1. New-PSDrive \\alvo\C$ (credencial)     |
      |------------------------------------------->|
      |  2. Copy-Item script -> C:\Windows\Temp     |
      |------------------------------------------->|
      |  3. Invoke-WmiMethod Win32_Process.Create   |
      |     (dispara o script via RPC/DCOM)         |
      |------------------------------------------->|
      |                                    [executa localmente]
      |                                    slmgr /ipk, /ato, etc.
      |                                    grava log em C:\ProgramData\...
      |                                    autoapaga o script
      |  4. Lê o log de volta via \\alvo\C$         |
      |<---------------------------------------------|
      |  5. Remove-PSDrive                          |
```

Esse desenho evita depender do WinRM (frequentemente desabilitado por
política em ambientes corporativos), usando só os dois mecanismos que já
costumam estar liberados em qualquer domínio Windows: SMB administrativo
(`C$`) e RPC/DCOM (porta 135), usados pelo WMI.

## Por que `-Scope Global` no `New-PSDrive`

Uma PSDrive criada dentro de uma função PowerShell, sem `-Scope Global`, é
destruída assim que a função retorna — mesmo que o valor de retorno (o nome
da drive) ainda seja usado pela função chamadora logo em seguida. Isso
causava o erro intermitente `Não é possível localizar a unidade` na
primeira versão da ferramenta: a drive existia durante a criação, mas já
tinha sumido no momento do `Copy-Item` seguinte. A correção foi garantir
`-Scope Global` tanto na criação quanto na limpeza (`Remove-PSDrive`) prévia.

## Limitação conhecida: leitura de log truncada

O mecanismo de espera pelo log remoto (`Invoke-EditionUpgrade` e afins) faz
polling por alguns segundos até ver o arquivo de log aparecer, e então lê seu
conteúdo. Em execuções mais lentas (aplicação de chave + tentativa de
ativação), o processo remoto pode ainda estar escrevendo a última linha no
momento em que a leitura acontece — resultando num "OK - log lido com
sucesso" que na verdade não capturou a conclusão real (sucesso ou erro da
ativação). O roadmap trata isso aguardando por uma linha de conclusão
explícita (ex: "Chave aplicada" ou "Produto ativado") em vez de confiar
apenas no primeiro tick do timer.
