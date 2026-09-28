# WinEditionTool

> Ferramenta corporativa em PowerShell + GUI para gerenciar remotamente a edição,
> versão e licenciamento do Windows em lote — sem precisar de WinRM.

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)](https://github.com/PowerShell/PowerShell)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6)]()
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

---

## ⚠️ Aviso legal

Esta ferramenta aplica **chaves de produto legítimas** (`slmgr /ipk`) em máquinas
Windows remotas. Use **apenas** em máquinas próprias ou em ambientes onde você
tenha autorização formal do responsável.

- O projeto **não distribui chaves** nem meios de burlar ativação.
- A chave informada é de responsabilidade exclusiva do operador.
- Cumpra os termos de licenciamento da Microsoft aplicáveis à sua organização.

---

## ✨ Funcionalidades

### 🖥️ Aba "Trocar edição"
- Troca a edição do Windows (`Pro` → `Education`, `Enterprise`, `Pro Education`, etc.)
  em **uma ou várias máquinas** ao mesmo tempo.
- Opção de **upgrade de versão** Windows 10 → 11 (opcional, na mesma aba),
  usando mídia oficial apontada por compartilhamento de rede.
- Detecta automaticamente se a máquina já está na edição correta — pode
  rodar quantas vezes quiser sem risco de duplicar aplicação.

### 🔍 Aba "Elegibilidade Windows 11"
- Verifica (sem alterar nada) se máquinas com Windows 10 atendem aos
  requisitos: TPM 2.0, Secure Boot/UEFI, RAM ≥ 4 GB, disco ≥ 64 GB, CPU básica.
- Reporta o modelo exato do processador para conferência manual na lista oficial da Microsoft.

### 🔐 Aba "Verificar licenciamento"
- Roda `slmgr /dli` remotamente e lista em lote quais máquinas estão sem
  licença válida (`Ative o Windows`), sem checar uma por uma.

### 🔧 Como funciona por baixo dos panos
- **WMI + compartilhamento administrativo (C$)** — não exige WinRM habilitado.
- Copia o script (materializado a partir de um bloco embutido no `.ps1` principal)
  pra `C:\Windows\Temp` na máquina remota, executa via `Win32_Process.Create`,
  lê o log de volta e o script remoto se **autoapaga** ao final da execução.
- Reinício agendado com aviso ao usuário logado (a cada logon e a cada 2h),
  forçado com 15 min de aviso quando o prazo estoura.

---

## 🚀 Instalação

### Pré-requisitos
- Windows 10 ou 11 na máquina de gestão.
- PowerShell 5.1+.
- Acesso de rede às máquinas alvo (porta 135 RPC/DCOM + compartilhamento `C$`).
- Credencial com permissão de **administrador local** nas máquinas de destino.

### Gerar o `.exe`
```powershell
git clone https://github.com/<seu-usuario>/WinEditionTool.git
cd WinEditionTool\build
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Build-EXE.ps1
```

`Build-EXE.ps1` instala o módulo público `ps2exe` (só na primeira vez) e gera
`WinEditionTool.exe` ao lado de `src\WinEditionTool.ps1`. O `.exe` pode então
ser copiado **sozinho** para qualquer computador Windows — não precisa mais
dos `.ps1`.

Ou, se preferir rodar como script (sem gerar `.exe`):
```powershell
.\src\WinEditionTool.ps1
```

### Instalador standalone (recomendado pra distribuir pra outras máquinas)

Em vez de copiar o `.exe` solto, o repositório inclui um instalador de
verdade em `installer/`: ele copia o `WinEditionTool.exe` pra
`C:\Program Files\WinEditionTool\`, cria atalho no Desktop e no Menu
Iniciar, e prepara a pasta de dados — tudo com 2 cliques, sem precisar abrir
PowerShell na máquina de destino.

```powershell
# 1. Gere o instalador (só uma vez, numa máquina com internet):
cd installer
.\Build-Instalador.ps1
# gera installer\Instalador.exe

# 2. Distribua a pasta installer\ (com o Instalador.exe) junto com o
#    WinEditionTool.exe já compilado (ou só o repositório inteiro — se
#    faltar o .exe, o instalador compila sozinho a partir de src\).
```

Na máquina de destino, quem for instalar só dá 2 cliques no
`Instalador.exe` (ele pede elevação de administrador sozinho). Não precisa
saber PowerShell nem rodar nada manualmente.

---

## 🧑‍💻 Uso

1. Abra o `WinEditionTool.exe` (ele pede elevação de administrador — normal).
2. Na primeira execução, é criada a pasta `WinEditionTool-Files\` ao lado do `.exe`,
   com os scripts remotos materializados e o `historico.csv`.
3. Preencha os campos:
   - **Computador(es):** um nome/IP por linha, ou clique em *Carregar CSV...*
     (veja `examples/maquinas-exemplo.csv` pro formato esperado).
   - **Edição de destino:** `Education`, `Enterprise`, `Pro Education`, `Pro`, etc.
   - **Versão do Windows** (opcional): manter a atual, ou forçar upgrade pra
     Windows 11 se a máquina ainda estiver no 10 (precisa de mídia em rede).
   - **Chave de produto:** a licença da sua organização.
   - **Dias de tolerância** antes do reinício forçado.
4. Clique em *Definir credencial de administrador...*
5. Clique em **Aplicar**. Em lote (2+ máquinas), pede confirmação e gera
   um `resultado_lote_AAAAMMDD_HHMMSS.csv` separado, além de registrar no
   `historico.csv` acumulado.

As abas "Elegibilidade Windows 11" e "Verificar licenciamento" funcionam do
mesmo jeito, mas **só leem** — não alteram nada nas máquinas.

---

## 📁 Estrutura do repositório

```
src/       WinEditionTool.ps1 — script único com a GUI e os scripts remotos
           embutidos como here-strings (materializados em disco só em runtime,
           na pasta WinEditionTool-Files\, ao lado do executável)
build/     Build-EXE.ps1 — empacota o .ps1 num .exe standalone via ps2exe
installer/ Install.ps1 (instalador) + Build-Instalador.ps1 (gera Instalador.exe)
docs/      documentação adicional e screenshots
examples/  CSVs de exemplo (sem dados reais)
```

> Nota: diferente de um projeto modularizado em vários `.ps1`, hoje a GUI e os
> scripts que rodam nas máquinas remotas (troca de edição, checagem de
> elegibilidade, verificação de licença, upgrade de versão) vivem todos dentro
> de `src/WinEditionTool.ps1`, como blocos de texto (here-strings) que são
> escritos em disco na primeira execução. Ver [Roadmap](#-roadmap) sobre
> planos de modularização.

---

## 🧪 Testado em

| Cenário                                                    | Resultado |
|-------------------------------------------------------------|-----------|
| Pro → Education (1 máquina)                                  | ✅        |
| Pro → Education (lote de 40+)                                 | ✅        |
| Reaplicar chave em máquina com "Ative o Windows" pendente     | ✅        |
| Verificar elegibilidade Win11                                 | ✅        |
| Verificar licenciamento em lote                               | ✅        |
| Upgrade de versão Win10 → Win11                                | ⚠️ testar antes em 1 máquina não crítica |

---

## 🛡️ Privacidade e limpeza automática

- A chave de produto é limpa do campo assim que a aplicação termina.
- A credencial de administrador é descartada da memória após cada lote.
- **Nenhuma senha** é gravada em disco, nem em log, em nenhum momento.
- O script copiado pra máquina remota se **autoapaga** ao término da execução.
- Os históricos gravados contêm apenas: nome da máquina, edição/status, detalhe, timestamp.

---

## 🐛 Limitações conhecidas

- Processa as máquinas do lote **em sequência**, não em paralelo — para
  listas grandes, calcule uns 25-30s por máquina.
- Em lotes grandes, o tempo de espera pela leitura do log remoto pode, em
  alguns casos, encerrar antes do script remoto terminar de escrever a
  última linha (aplicação de chave / ativação) — o resultado aparece como
  "OK" mas sem confirmar o status final. Veja o [CHANGELOG](CHANGELOG.md).
- Depende de acesso ao compartilhamento administrativo `C$` e à porta 135
  (RPC/DCOM) nas máquinas de destino.

---

## 🗺️ Roadmap

- Separar a lógica de negócio (scripts remotos) do `.ps1` principal em um
  módulo `.psm1`, deixando o `.ps1` só com a GUI.
- Aguardar uma linha de conclusão explícita no log remoto antes de reportar
  "OK", em vez de confiar no primeiro tick do timer de leitura.
- Execução paralela para lotes grandes.

---

## 🤝 Contribuindo

Veja [CONTRIBUTING.md](CONTRIBUTING.md). PRs, issues e sugestões são bem-vindos.

## 📜 Changelog

Veja [CHANGELOG.md](CHANGELOG.md).

## 📄 Licença

MIT — veja [LICENSE](LICENSE).
