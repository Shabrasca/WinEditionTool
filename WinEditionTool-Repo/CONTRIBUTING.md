# Contribuindo

1. Faça um fork.
2. Crie uma branch: `git checkout -b feat/minha-feature`.
3. Commit seguindo [Conventional Commits](https://www.conventionalcommits.org/).
4. Abra um PR descrevendo o cenário testado (qual aba, quantas máquinas, Windows 10 ou 11).

## Antes de abrir o PR

- Rode o parser de sintaxe do PowerShell no arquivo alterado:
  ```powershell
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile("src/WinEditionTool.ps1", [ref]$null, [ref]$errors)
  if ($errors.Count -eq 0) { "OK" } else { $errors }
  ```
- Não inclua nomes reais de máquinas, usuários ou domínios nos exemplos — use `PC-001`, `usuario.exemplo`, etc.
- Não commite chaves de produto, senhas ou arquivos de histórico (o `.gitignore` já cobre a maioria, mas confira antes do `git add`).
