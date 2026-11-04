# WiseDB: coleta para relatórios (Crescimento e Backups)

Wizard de uma linha que descobre os bancos do servidor (Oracle, SQL Server, PostgreSQL, MySQL/MariaDB, MongoDB), coleta só metadados com consultas de leitura e envia um JSON para o link exclusivo do cliente. A WiseDB fornece o comando completo, com o link e o SHA-256 da versão.

- Linux: `linux/wisedb-coleta.sh` (bash 4.2+, como root). Instruções em `linux/LEIAME.md`.
- Windows: `windows/wisedb-coleta.ps1` (PowerShell 5.1, como Administrador). Instruções em `windows/LEIAME.md`.
- Formato dos dados: `contrato/CONTRATO_v1.md`.

Sempre confira o SHA-256 antes de executar. Não use `-k` nem desative TLS.
