# wisedb-coleta (Linux)

Wizard de coleta da WiseDB: um único script bash. Descobre os bancos do servidor (Oracle, SQL Server, MySQL/MariaDB, PostgreSQL, MongoDB) e o ambiente de nuvem, coleta **só metadados** com SQL de leitura, monta um JSON (`wisedb.coleta/1`, ver `../contrato/CONTRATO_v1.md`) e envia por HTTPS PUT para um link PAR da OCI. Nenhum binário é instalado.

## Pré-requisitos

- bash 4.2+ (Oracle Linux 7+, RHEL, Ubuntu), coreutils, `curl`, `gzip`, `awk`, `sed`. Python não é necessário.
- Rodar como **root** (`sudo`): o wizard alterna para o usuário dono de cada banco (`runuser`/`su`). Sem root ele avisa e coleta só o que o usuário atual alcança.
- Saída HTTPS (443) para `objectstorage.<região>.oraclecloud.com`. Sem `-k`: o certificado é verificado.
- Clientes dos bancos já instalados no servidor: `sqlplus` (do ORACLE_HOME), `sqlcmd`, `mysql`/`mariadb`, `psql`, `mongosh`/`mongo`. Sem o cliente, o inventário marca `acesso=sem_cliente`.

## Comando de uma linha

Substitua `<URL_DO_WIZARD>`, `<SHA256>`, `<ID_CLIENTE>` e `<LINK_PAR>` (termina em `/o/`). O arquivo só roda se o SHA-256 conferir:

```bash
f=$(mktemp) && curl -fsSL -o "$f" <URL_DO_WIZARD> && echo "<SHA256>  $f" | sha256sum -c - && sudo bash "$f" --cliente <ID_CLIENTE> --link '<LINK_PAR>'
```

Primeiro olhar, sem coletar nem enviar (troque o final por `--descobrir`):

```bash
... && sudo bash "$f" --descobrir
```

Agendar (grava o conf e 1 linha no crontab do root; o cron baixa a mesma URL, confere o hash e roda):

```bash
... && sudo bash "$f" --agendar diario --cliente <ID_CLIENTE> --link '<LINK_PAR>' --url-wizard <URL_DO_WIZARD> --sha256 <SHA256>
```

## Opções

| Opção | O que faz |
|---|---|
| `--descobrir` | Mostra o inventário (bancos, versão, acesso, nuvem, CLIs). Não coleta nem envia. |
| `--coletar --saida ARQ.json.gz` | Coleta e grava o arquivo. Não envia. |
| (padrão) `--cliente ID --link URL` | Coleta e envia. `--saida` junto guarda uma cópia local. |
| `--enviar-arquivo ARQ.json.gz` | Reenvia um arquivo gerado antes por `--coletar`. |
| `--agendar diario\|semanal` | Grava `/etc/wisedb/coleta.conf` (600) e a linha do cron (`# wisedb-coleta`), hora derivada do host (01h a 04h; semanal na segunda). Exige `--url-wizard` e `--sha256` (e confere o hash do próprio arquivo). |
| `--remover-agendamento` | Remove a linha do cron. Com `--apagar-conf` remove também o conf e o log. |
| `--timeout SEG` | Limite por consulta (padrão 120). |

Link: `--link` > variável `WISEDB_LINK` > `/etc/wisedb/coleta.conf`. O link **nunca** é impresso inteiro (só 30 caracteres). Prefira o conf ou `WISEDB_LINK` ao `--link`, porque argumentos aparecem em `ps`.

Variáveis opcionais, lidas só na execução e nunca gravadas em JSON, conf ou log: `WISEDB_MSSQL_USER` e `WISEDB_MSSQL_PASS` (SQL Server; a senha vai por `SQLCMDPASSWORD`), `WISEDB_MONGO_URI` (MongoDB com autenticação; a URI aparece em `ps` durante a consulta).

## Descoberta e autenticação

| Motor | Como acha | Como entra |
|---|---|---|
| Oracle | processos `ora_pmon_*`, `/etc/oratab`; `ORACLE_HOME` do `environ` do pmon (depois `exe`, depois oratab); dono do processo | `/ as sysdba` como o dono do pmon. SID só no oratab: `acesso=erro` (instância parada). |
| SQL Server | processo `sqlservr`, porta em LISTEN, `sqlcmd` em `/opt/mssql-tools*/bin` | Só com `WISEDB_MSSQL_USER/PASS` (não há autenticação integrada no Linux); sem elas: `sem_credencial`. |
| MySQL/MariaDB | `mysqld`/`mariadbd`, socket e porta do processo | Cliente como o usuário atual (root): `auth_socket` ou `~root/.my.cnf`; em Debian/Ubuntu tenta também `/etc/mysql/debian.cnf`. |
| PostgreSQL | `postgres`/`postmaster` (`postmaster.pid`: porta e diretório do socket), `psql` do mesmo `bin` | `psql` como o dono do processo (peer), sessão `default_transaction_read_only=on`. |
| MongoDB | `mongod`, porta; `mongosh` ou `mongo` | localhost sem autenticação; com auth, `WISEDB_MONGO_URI`. |

Bancos em **containers** (processo em outro namespace de rede) aparecem com `acesso=erro` e não são consultados; para esses, rode o wizard dentro do container.

Quando não entra: a instância aparece no inventário com `acesso=sem_credencial|sem_cliente|erro`, `detalhe` curto e um aviso. O wizard nunca grava senha.

## O que é coletado

| Motor | `crescimento[]` (bytes alocados) | `backups[]` (janela de 35 dias) |
|---|---|---|
| Oracle | `total` + `tablespace` (soma de `dba_data_files`, sem tempfiles); em CDB uma linha `total` por PDB (`subbase` = PDB; `base` = nome do CDB); PDB fechado vira aviso. Sem AWR/ASH. | RMAN (`v$rman_backup_job_details`; Level 0 = FULL, Level 1 = INCREMENTAL; sem `v$backup_set_details`, tudo INCR vira INCREMENTAL); expdp: logs `*.log` dos diretórios do banco (`dba_directories`; em CDB `cdb_directories`) modificados nos últimos 35 dias, parser do kit de Backups (`LOGICO_FULL` para FULL, `LOGICO_SCHEMA` para o resto). |
| SQL Server | `total` por base (`sys.master_files`, só dados) + `filegroup` (`sys.database_files`); `tempdb` fora; base offline vira aviso. | `msdb.dbo.backupset` (D=FULL, I=DIFERENCIAL, L=LOG), dispositivo pela `backupmediafamily` (DISK, SBT_TAPE, URL, OCI). `is_damaged` vira FALHA. Falha de backup não fica no msdb. |
| PostgreSQL | `total` (`pg_database_size`) por base + `schema` (soma de `pg_total_relation_size` de tabelas e matviews; sem `pg_*` e `information_schema`); templates fora. | pgBackRest (`info --output=json`, precisa de `python3`); outras ferramentas só viram aviso. |
| MySQL/MariaDB | `base` = `mysql` ou `mariadb`; `schema` por schema (`data_length + index_length`) e `total` = soma; schemas de sistema fora. | Só aviso das ferramentas detectadas. |
| MongoDB | `total` por base (`dbStats`: `storageSize + indexSize`) + `collection` (`collStats`); `admin`, `local`, `config` fora. | Só aviso das ferramentas detectadas. |

Horários de backup vêm no fuso local do servidor e são convertidos para UTC (`Z`) com o `date` do sistema. Se o banco usa um fuso diferente do SO, o horário sai deslocado.

Nuvem: metadado com timeout de 2 s (OCI, Azure, GCP, AWS IMDSv2) preenche `host.nuvem` e `host.instancia_id`; CLIs `oci`, `aws`, `az`, `gcloud` entram em `nuvem.cli_detectadas` só se estiverem autenticadas (senão, aviso).

## O que fica no servidor

- Nada instalado. Só, se você rodar `--agendar`: `/etc/wisedb/coleta.conf` (600: ID, link, URL e SHA-256 do wizard), 1 linha no crontab do root e `/var/log/wisedb-coleta.log` (600, sem segredos, truncado acima de 1 MB).
- Temporários em `/tmp/wisedb-coleta.*` (apagados ao sair) e lock em `/var/lock/wisedb-coleta.lock`.
- Nos bancos: apenas `SELECT` (Oracle sem AWR; PostgreSQL em transação somente leitura). Nenhum objeto criado.

## Como remover

```bash
sudo bash wisedb-coleta.sh --remover-agendamento --apagar-conf
```

Isso tira a linha do cron e apaga `/etc/wisedb` e o log. Não sobra mais nada.

## Códigos de saída

`0` ok | `1` uso/parâmetros | `2` já em execução | `3` pré-requisito ausente | `4` havia instâncias e nenhuma foi coletada (o JSON ainda é gerado/enviado) | `5` falha ao montar o JSON/gzip | `6` falha no envio (HTTP diferente de 200) | `7` falha no agendamento/configuração (inclui hash do script diferente do informado).

## Testes

`testes/`: `validar_coleta.py` (validador do contrato), `t_reais.sh` (PostgreSQL 16, MariaDB 11 e MongoDB 7 em container), `mock_run.sh` + `t_mocks.sh` + `assert_mocks.py` (Oracle e SQL Server com `sqlplus` e `sqlcmd` falsos, agendamento com `crontab` e `curl` falsos), `t_host.sh` (Oracle Linux 7 real, metadado OCI e envio real a um link PAR de teste).
