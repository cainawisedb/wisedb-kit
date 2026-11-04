# WiseDB coleta (Windows) v1.0.0

Script único (`wisedb-coleta.ps1`) que descobre SQL Server e Oracle, coleta **só metadados, somente leitura**, monta um JSON (`wisedb.coleta/1`, ver `contrato/CONTRATO_v1.md`) e envia por HTTPS PUT a um link PAR da OCI (grava só no prefixo do cliente; não lê nem apaga). MySQL, PostgreSQL e MongoDB são apenas detectados (serviço).

## Pré-requisitos

- Windows Server 2012 R2 ou superior com **PowerShell 5.1** (2012 R2 precisa do WMF 5.1). Sem módulos externos, sem instalação.
- Saída HTTPS (443) para `objectstorage.<região>.oraclecloud.com`.
- SQL Server: o usuário que roda precisa de login (autenticação integrada) com `VIEW ANY DEFINITION` e `VIEW ANY DATABASE`, e leitura em `msdb` (`backupset`, `backupmediafamily`; jobs: `SQLAgentReaderRole`). Instância nomeada usa `localhost\NOME` (precisa do serviço SQL Browser ou porta fixa).
- Oracle: `sqlplus.exe` (PATH, `ORACLE_HOME` ou registro) e usuário do Windows no grupo `ORA_DBA` (`/ as sysdba`). Nenhuma senha é pedida.
- Agendar/remover: PowerShell como **Administrador**.

## Comando de uma linha (baixa, confere o SHA-256 e executa)

Substitua `<ORG/REPO/TAG>`, `<SHA256>`, `<ID>` e `<LINK_PAR>` (o link termina em `/o/`):

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; $u='https://raw.githubusercontent.com/<ORG/REPO/TAG>/windows/wisedb-coleta.ps1'; $h='<SHA256>'; $f="$env:TEMP\wisedb-coleta.ps1"; iwr $u -UseBasicParsing -OutFile $f; if((Get-FileHash $f -Algorithm SHA256).Hash -ne $h){ throw 'SHA-256 diferente: nao execute' }; & $f -Cliente <ID> -Link '<LINK_PAR>'
```

Para agendar (como Administrador), acrescente `-Agendar Semanal -UrlScript $u -Sha256 $h` ao final.

## Opções

| Opção | Efeito |
|---|---|
| (padrão) | coleta e envia (`-Cliente` e `-Link`, ou `coleta.conf`) |
| `-Descobrir` | só lista instâncias e o acesso de cada uma (nenhum envio) |
| `-Coletar -Saida arq.json.gz` | coleta e grava o arquivo, sem enviar |
| `-Agendar Diario\|Semanal` | grava `coleta.conf` e cria a Tarefa Agendada `WiseDB Coleta` (SYSTEM, 02:30 + até 20 min aleatórios; semanal = segunda) |
| `-RemoverAgendamento` | remove a tarefa e a pasta `C:\ProgramData\WiseDB` |
| `-SqlCredencial (Get-Credential)` | login SQL em vez de autenticação integrada (também: variáveis `WISEDB_SQL_USER` e `WISEDB_SQL_PASSWORD`). Nunca é gravado |
| `-JanelaDias 35`, `-TimeoutConsulta 120` | janela de backups e timeout por consulta (s) |
| `-Simular <pasta>` | **só teste**: lê fixtures em vez de conectar nos bancos |

Códigos de saída: 0 ok (inclui coleta parcial, veja `avisos`); 1 uso; 2 exige Administrador; 3 configuração (cliente, link, `coleta.conf`); 4 nada coletado (nada é enviado); 5 falha de envio (3 tentativas; 4xx não repete); 6 erro interno/fixtures.

## O que é coletado

- **Crescimento (SQL Server):** por base, uma linha `total` e uma por `filegroup` (`sys.master_files` + `sys.filegroups`, bytes = páginas × 8192). **Total = só arquivos de dados** (mesma regra do Oracle, que exclui tempfiles); `tempdb` fora. O tamanho do log vai no campo opcional `bytes_log` da linha `total` (o contrato não tem componente `LOG`). Base offline/restaurando: só o `total`.
- **Crescimento (Oracle):** mesma consulta do kit (`dba/cdb_data_files`, sem tempfiles; CDB: um total por PDB, `CDB$ROOT` e seed fora), em bytes.
- **Backups SQL Server:** `msdb.dbo.backupset`, últimos 35 dias; `D`=FULL, `I`=DIFERENCIAL, `L`=LOG; dispositivo 2=DISK, 5=SBT_TAPE, 9=URL (7, dispositivo virtual de terceiros, fica `null`). `is_damaged=1` ou `has_incomplete_metadata=1` = WARNING; os demais, SUCESSO. Backups para `NUL` são ignorados.
- **Backups Oracle:** `v$rman_backup_job_details` (Level 0 = FULL via `v$backup_set_details`; fallback sem nível, avisado). `expdp` não é coletado nesta versão.
- **Nuvem:** provedor por metadados (OCI, AWS IMDSv2, Azure, GCP; timeout 2 s) e CLIs `oci`, `aws`, `az`, `gcloud` encontradas (sem testar login).

**Limitação conhecida (SQL Server):** o `msdb` só registra backup concluído. Backup que falhou não aparece no `backupset`, então **não há linha FALHA**. Falhas de job de backup (resultado do job, últimos 35 dias) saem em `avisos`, sem identificar a base.

## O que fica no servidor

- Nada instalado. Sem `-Agendar`: nada permanece (a pasta temporária com ACL restrita é apagada ao fim).
- Com `-Agendar`: `C:\ProgramData\WiseDB\coleta.conf` (ACL só SYSTEM e Administradores: cliente, link, URL e SHA-256 da versão publicada) e a Tarefa Agendada `WiseDB Coleta`. A cada execução a tarefa baixa a versão publicada para essa pasta, confere o SHA-256 com `Get-FileHash`, só então executa e apaga o arquivo baixado.
- Segurança: o link nunca é impresso por inteiro (30 caracteres); senha nunca é gravada; o JSON só leva metadados (sem dados de negócio).

## Permissões da conta SYSTEM (tarefa agendada)

No SQL Server a conta `NT AUTHORITY\SYSTEM` não é sysadmin por padrão. O DBA decide e executa (o script não altera nada), por exemplo:

```sql
CREATE LOGIN [NT AUTHORITY\SYSTEM] FROM WINDOWS;
GRANT VIEW ANY DATABASE TO [NT AUTHORITY\SYSTEM];
GRANT VIEW ANY DEFINITION TO [NT AUTHORITY\SYSTEM];
USE msdb; CREATE USER [NT AUTHORITY\SYSTEM] FOR LOGIN [NT AUTHORITY\SYSTEM];
ALTER ROLE db_datareader ADD MEMBER [NT AUTHORITY\SYSTEM];
ALTER ROLE SQLAgentReaderRole ADD MEMBER [NT AUTHORITY\SYSTEM];
```

Alternativa: agendar manualmente com uma conta de serviço do domínio que já tenha esses acessos.

## Remover

Como Administrador: `& .\wisedb-coleta.ps1 -RemoverAgendamento`. Sem agendamento, não há o que remover.

## Testes

`testes\run-tests.ps1` (parser, simulação com fixtures, validador do contrato, casos negativos), `testes\validar-contrato.ps1 -Arquivo x.json.gz`. Não precisam de SQL Server, Oracle nem rede.
