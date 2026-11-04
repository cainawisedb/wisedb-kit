# Contrato da coleta WiseDB, versão 1 (`wisedb.coleta/1`)

Fonte única para o wizard (Linux e Windows) e para a ingestão no bastion. Mudança incompatível = nova versão (`/2`); campos novos opcionais podem entrar na `/1`.

## Arquitetura

```
Servidor do cliente                         OCI (tenancy WiseDB)                  Bastion
wizard (bash ou PowerShell)   HTTPS PUT     bucket Backup-Report                  wisedb ingest-coleta
 descobre bancos e nuvem   ─────────────►   <ID>/coleta/<host>/<ts>.json.gz  ◄──  (oci os, perfil de leitura)
 SQL só leitura             link PAR do      link só grava neste prefixo            valida, deduplica,
 monta 1 JSON              cliente          (não lê, não apaga, expira)            grava no SQLite do Lite
```

- **Sem chave no cliente.** Cada cliente recebe um link PAR (`AnyObjectWrite`) restrito ao prefixo `<ID>/coleta/`, com validade de 12 meses. Testado: grava no prefixo (200), é recusado fora dele (401) e não lê (404). Rotação = criar novo link e revogar o antigo.
- **Sem servidor exposto.** Não há porta aberta no bastion. Quando houver API Gateway, ele aceita o mesmo JSON; só muda o destino do `PUT`.
- **No cliente fica só:** `/etc/wisedb/coleta.conf` (600: ID e link) e uma linha de agendamento (cron ou Tarefa Agendada) que roda o wizard publicado, conferindo o SHA-256. Nenhum binário instalado.

## Envelope

Arquivo: `<cliente_id>/coleta/<host_nome>/<AAAAMMDDTHHMMSSZ>.json.gz` (gzip de UTF-8, sem BOM).

```json
{
  "schema": "wisedb.coleta/1",
  "cliente_id": "Informata",
  "coletado_em": "2026-11-04T13:00:00Z",
  "agente": {"nome": "wisedb-coleta", "versao": "1.0.0", "plataforma": "linux"},
  "host": {"nome": "srvdb01", "so": "Oracle Linux 8.9", "nuvem": "oci", "instancia_id": null},
  "inventario": [],
  "crescimento": [],
  "backups": [],
  "nuvem": {"cli_detectadas": [], "itens": []},
  "avisos": []
}
```

Regras gerais: datas em ISO 8601 UTC com `Z`; tamanhos em **bytes inteiros**; texto livre sem quebra de linha; nada de senha, string de conexão ou dado de negócio (só metadado de banco).

### `inventario[]` (uma linha por instância encontrada)

| campo | tipo | valores |
|---|---|---|
| `motor` | texto | `oracle`, `sqlserver`, `mysql`, `postgresql`, `mongodb` |
| `instancia` | texto | SID, nome da instância SQL Server, porta, etc. |
| `versao` | texto ou null | versão reportada pelo motor |
| `acesso` | texto | `ok`, `sem_credencial`, `sem_cliente` (sem sqlplus/psql...), `erro` |
| `detalhe` | texto ou null | motivo curto quando não é `ok` |

### `crescimento[]` (foto do momento; o histórico mensal é montado no bastion)

| campo | tipo | observação |
|---|---|---|
| `motor`, `instancia` | texto | como no inventário |
| `base` | texto | nome do banco (Oracle: `DB_NAME`; CDB: nome do CDB) |
| `subbase` | texto ou null | PDB no Oracle; null nos demais |
| `componente_tipo` | texto | `total`, `tablespace`, `filegroup`, `schema`, `database`, `collection` |
| `componente` | texto | nome; para `total`, igual a `base` |
| `bytes` | inteiro | alocado (Oracle: soma de `dba_data_files.bytes`, sem tempfiles) |
| `medido_em` | ISO | instante da consulta |

Toda `base`(+`subbase`) tem exatamente uma linha `total`.

### `backups[]` (histórico recente; o bastion deduplica)

| campo | tipo | valores |
|---|---|---|
| `motor`, `instancia`, `base` | texto | |
| `origem` | texto | `rman`, `expdp`, `msdb`, `pgbackrest`, `outro` |
| `tipo` | texto | `FULL`, `INCREMENTAL`, `DIFERENCIAL`, `LOG`, `LOGICO_FULL`, `LOGICO_SCHEMA` |
| `dispositivo` | texto ou null | `DISK`, `SBT_TAPE`, `URL`, `OCI` |
| `inicio`, `fim` | ISO | `fim` null se desconhecido |
| `status` | texto | `SUCESSO`, `WARNING`, `FALHA` |
| `bytes` | inteiro ou null | tamanho gerado |
| `objetos` | inteiro ou null | só lógicos (expdp: linhas `. . exported`) |

Chave de deduplicação no bastion: `cliente_id + host + motor + instancia + base + origem + tipo + inicio + dispositivo`.

Janela: Oracle RMAN últimos 35 dias; SQL Server msdb últimos 35 dias; expdp logs modificados nos últimos 35 dias.

### `nuvem`

`cli_detectadas`: nomes das CLIs encontradas e autenticadas (`oci`, `aws`, `az`, `gcloud`). `itens[]`: livre por provedor, com `provedor`, `tipo` (ex.: `boot_volume_backup`) e campos do provedor. Opcional na v1; o FinOps continua sendo puxado pelo bastion.

### `avisos[]`

Frases curtas do que não foi coletado e por quê (ex.: `mysql 3306: sem credencial`). Nunca valores sensíveis.

## Mapeamento para os relatórios

- **Crescimento:** `crescimento[]` → `fact_capacity_snapshot` (bytes, UTC). Valor do mês = última foto do mês. Rótulo de componente por motor já existe no Lite (`tablespaces`, `filegroups`, `schemas`, `collections`).
- **Backups:** `origem=rman` e `msdb` → linhas de backup físico; `expdp` → backup lógico. O bastion gera os CSV no formato do relatório de Backups em `paralelo/coleta/<ID>/dataset/`.
