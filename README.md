# wisedb-kit
wisedb-kit | Coleta de dados para geração de política de backup

Linux, com acesso ao GitHub:
`bash <(curl -fsSL https://raw.githubusercontent.com/cainawisedb/wisedb-kit/main/wisedb_coleta_auto.sh)`

Linux, sem internet (pasta completa do kit no servidor):
`cd <pasta_do_kit> && bash wisedb_coleta_auto.sh`

Linux sem internet e sem transferência de arquivo (senhasegura): `bash gerar_colagem_senhasegura.sh` gera um texto de poucas linhas para colar no servidor; depois `cd ~/wisedb-kit && WISEDB_OFFLINE=1 bash wisedb_coleta_auto.sh`.

Windows: `powershell -ExecutionPolicy Bypass -File .\wisedb_coleta_auto.ps1` (de dentro da pasta do kit).

Detalhes no LEIA-ME.md.
