# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/)
e versionamento [SemVer](https://semver.org/lang/pt-BR/).

## [Unreleased]
### Planejado
- Suporte a execução paralela (lotes grandes).
- Exportação direta pra Excel (`.xlsx`) dos resultados.
- Checagem de status de ativação via CIM/WMI direto (sem copiar script), como alternativa mais rápida à aba "Verificar licenciamento" para diagnósticos pontuais.

## [1.1.0] - 2026-09-28
### Adicionado
- Aba "Verificar licenciamento" (`slmgr /dli` remoto).
- Aba "Elegibilidade Windows 11" (TPM, Secure Boot, RAM, disco, CPU).
- Upgrade opcional de versão Win10 → Win11 via mídia de rede, dentro da aba "Trocar edição".
- Botão "Verificar progresso do upgrade Win11".
- Retry automático na gravação dos históricos + arquivo `.pendentes`.

### Corrigido
- Comparação de edição agora usa `EditionID` exato (evita confundir
  `Education` com `ProfessionalEducation`).
- `New-PSDrive` agora usa `-Scope Global` (bug intermitente "unidade não encontrada"
  causado pela drive sendo destruída ao sair do escopo da função que a criava).
- Cancelar credencial não deixa mais rótulo com valor antigo.
- Deduplicação case-insensitive de nomes de máquina.
- Remoção de aspas/crases da chave antes de montar o comando remoto.

### Conhecido (em investigação)
- Em lotes grandes, o tempo de espera pela leitura do log remoto pode encerrar
  antes do script remoto terminar de escrever a última linha (aplicação de
  chave / ativação), fazendo o resultado aparecer como "OK" sem confirmar o
  status final. Workaround atual: reverificar com a aba "Verificar
  licenciamento" ou com um script de checagem via CIM/WMI direto.

## [1.0.0] - 2026-09-10
### Adicionado
- Versão inicial com GUI, WMI remoto, troca de edição em lote,
  agendamento de reinício, histórico CSV.
