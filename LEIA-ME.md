# Kit de Coleta para Política de Backup - WiseDB

## Modo automático (recomendado): execução via link, sem SCP

Publique este kit em um repositório (GitHub, por exemplo) e rode UMA linha no servidor alvo. O orquestrador detecta o ambiente, baixa da mesma origem apenas os módulos necessários, conduz o wizard (incluir/remover itens e marcar ambientes fora do escopo da política, com justificativa), coleta, sanitiza, mostra o resumo e, após o "OK", gera `resultado_final.txt` (para colar na IA) e `resultado.json` (estruturado para integrações futuras).

```bash
# Linux (usuario oracle ou dono das rotinas):
bash <(curl -fsSL https://raw.githubusercontent.com/cainawisedb/wisedb-kit/main/wisedb_coleta_auto.sh)
# So se aparecer "curl: (60)" (CA antiga): troque curl -fsSL por curl -kfsSL
```
```powershell
# Windows (PowerShell como administrador, PS 3.0+):
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$env:WISEDB_BASE_URL="https://raw.githubusercontent.com/cainawisedb/wisedb-kit/main"
Invoke-WebRequest -Uri "$env:WISEDB_BASE_URL/wisedb_coleta_auto.ps1" -OutFile "wisedb_coleta_auto.ps1" -UseBasicParsing
powershell -ExecutionPolicy Bypass -File ".\wisedb_coleta_auto.ps1"
```
Manual completo do fluxo para colaboradores: M-001 v2.0.

### Ambiente sem internet (VPN, PAM/senhasegura, firewall)

Baixe o repositório atual pelo botão **Code > Download ZIP** do GitHub, leve a pasta inteira para o servidor e rode de dentro dela:

```bash
cd /caminho/da/pasta/do/kit && bash wisedb_coleta_auto.sh
```
```powershell
cd C:\caminho\do\kit; powershell -ExecutionPolicy Bypass -File .\wisedb_coleta_auto.ps1
```

A partir da v3.9 (Linux) e v2.5 (Windows), o orquestrador identifica a origem dos módulos logo após a linha `Host:` e mostra na tela:

| Como foi chamado | Origem | Comportamento |
|---|---|---|
| Arquivo dentro da pasta do kit | `LOCAL` | Usa só os arquivos da pasta. Nenhum acesso à rede para buscar módulos. |
| Link (`bash <(curl ...)`, `irm \| iex` ou bootstrap) com GitHub acessível | `GITHUB` | Baixa os módulos na mesma versão do orquestrador. |
| Link, GitHub sem resposta, com cópia local na pasta atual ou em `./kit_coleta_backup` | `LOCAL` | Cai para a cópia local em no máximo ~20 s. |
| Link, GitHub sem resposta e sem cópia local | aborta | Encerra em segundos com a instrução acima. |

Até a v3.8 o teste de acesso ao GitHub não tinha timeout: em rede que descarta pacotes, a tela parava logo após `Host: ... | Usuario: ...`. Se encontrar um servidor ainda com a v3.8, o contorno sem trocar arquivos é rodar dentro da pasta do kit: `WISEDB_BASE_URL=http://127.0.0.1:9 bash wisedb_coleta_auto.sh`.

Variáveis úteis: `WISEDB_OFFLINE=1` força o modo local; `WISEDB_KIT_DIR=/caminho` aponta a pasta do kit; `WISEDB_NET_TIMEOUT` (padrão 20 s) limita o teste de acesso ao GitHub. A origem usada fica registrada em `nivel_privilegio_coleta.txt` e no `resultado.json` (`coleta.origem_modulos`).

Cuidado ao limpar a pasta do kit: as coletas são gravadas como `wisedb_coleta_<cliente>_...`, e um `rm wisedb_coleta_*` apaga junto os orquestradores (`wisedb_coleta_auto.sh/.ps1` e o bootstrap). Apague pelo nome completo da pasta da coleta.

O antigo `wisedb-kit-offline.tar.gz` foi descontinuado (parou na v3.3, sem os módulos 08 a 12 e com a máscara antiga de segredos).

### Servidor sem internet e sem transferência de arquivo (senhasegura)

Quando o servidor só é acessível por PAM (ex.: Unimed JP via senhasegura), sem GitHub e sem WinSCP, o kit vai como **texto de colagem**: poucas linhas longas (base64), porque o senhasegura cola cerca de uma linha por segundo.

1. Num Linux com o kit (bastion ou WSL), gere o texto: `bash gerar_colagem_senhasegura.sh` (kit completo, ~14 linhas). Para só atualizar um kit já instalado: `bash gerar_colagem_senhasegura.sh -p wisedb_coleta_auto.sh` (arquivos alterados).
2. Abra o `.txt` gerado, copie tudo e cole na sessão do servidor, já logado com o usuário da coleta (ex.: oracle). Não digite nada até aparecer `[WiseDB] KIT OK` (ou `ERRO`, e então cole de novo).
3. Rode a coleta: `cd ~/wisedb-kit && WISEDB_OFFLINE=1 bash wisedb_coleta_auto.sh`

O kit fica em `~/wisedb-kit`; para outra pasta, digite `WK=/outra/pasta` antes de colar. As linhas da colagem não ficam no histórico do shell. Se a sessão cortar linhas longas, gere com linhas menores: `-l 4000`.

### sudo (a partir da v4.0.1)

O wizard não pergunta mais sobre sudo para usuário sem sinal de sudo (oracle, postgres e afins): segue sem sudo e registra `/etc/crontab`, `/etc/cron.d` e dbcli como pendência no RESUMO. sudo sem senha continua detectado sozinho. A pergunta (padrão **N**) só aparece para root, grupo wheel/sudo/admin ou usuário de nuvem (opc, ec2-user...). `WISEDB_SUDO=1` força a tentativa com senha; `WISEDB_SUDO=0` desliga. Motivo: a tentativa com senha negada gera "NOT in sudoers" no log de segurança do cliente.

Para fechar a pendência sem sudo, peça à equipe de infraestrutura do cliente a saída de `crontab -l -u root; cat /etc/crontab; ls -l /etc/cron.d` e anexe ao RESUMO.

### Terminal web/PAM (corrigido na v4.0.1)

Até a v4.0, em terminal que envia CR+LF no ENTER (senhasegura e afins) os menus de instâncias Oracle e de diretórios eram confirmados sozinhos, com tudo incluído, e "não" na pergunta de sudo era lido como sim. A v4.0.1 descarta o que sobra no terminal a cada pergunta e aceita s/sim/n/não em qualquer grafia. Nos menus de múltipla escolha, ENTER sem marcar nada continua significando **todas**.

### Vulnerabilidades e inconformidades (módulo 13, a partir da v4.0)

Toda coleta completa com coleta local roda o módulo 13 (`13_coleta_seguranca_conformidade.sh` no Linux, `13_coleta_seguranca_windows.ps1` no Windows). Somente leitura; nenhum valor de senha é lido ou gravado. **Rode o kit no servidor de banco e também no servidor/repositório de backup**: cada lado enxerga riscos diferentes.

| Lado | O que é verificado |
|---|---|
| Servidor de banco | Repositório de backup (NFS/CIFS/unidade mapeada) montado com escrita permanente; NFS soft, sec=sys, wsize baixo, sem dNFS; backup no mesmo filesystem dos dados; permissões de diretórios e dumps; credencial de off-site no servidor de produção |
| Oracle (por instância) | NOARCHIVELOG, retenção (REDUNDANCY 1, janela curta), quantidade de fulls disponíveis, full antigo, janela de backup, falhas, ausência de VALIDATE, criptografia, autobackup de controlfile, BCT (EE), FRA, atraso de archivelog, versão fora de suporte |
| Scripts do cron | Exclusão do backup anterior antes do novo full (ambiente sem backup durante a janela) |
| Servidor de backup | Exports NFS abertos (`*` ou rede ampla), `no_root_squash`, `insecure`, `sec=sys`; imutabilidade (atributo imutável, Veeam Hardened Repository), snapshots e deduplicação |
| Ambos | SO fora de suporte, dias sem atualização, firewall, SSH (root/senha), SELinux, auditd, NTP, antivírus/EDR; no Windows também SMBv1, RDP sem NLA, shares e pastas de backup com escrita para Todos/Usuários |

O digest 2.6 consolida tudo em uma matriz única (IDs `VUL-xxx`), junto com os alertas existentes e os critérios 3-2-1-1-0 não atendidos, e gera:

- seção **VULNERABILIDADES E INCONFORMIDADES** no RESUMO (vai para a política, seção 9);
- `MATRIZ_VULNERABILIDADES.tsv` (abre no Excel; base para o Painel);
- seção **INSUMO COMERCIAL** no RESUMO e `OPORTUNIDADES_COMERCIAIS_INTERNO.txt`: achados agrupados por oportunidade de adequação, com prioridade (P1 a P4) e solução de referência. **Uso interno, não enviar ao cliente.**

Para apontar outro repositório sem editar o script: `export WISEDB_BASE_URL="https://.../kit_coleta_backup"` antes de rodar (Linux) ou `$env:WISEDB_BASE_URL = "..."` (Windows). Repositório privado funciona incluindo o token de leitura na URL raw.


### Blindagens do wizard (v3.0)

O wizard nunca assume que o servidor onde roda pertence ao cliente. Antes de coletar, ele:

1. **Classifica o papel do host**: HOST DO CLIENTE, ESTAÇÃO DE COLETA/BASTION WiseDB ou HOST MISTO. Em estação de coleta, os dados locais (cron, discos, bases) são suprimidos da política e gravados em `contexto_estacao_NAO_DO_CLIENTE.txt`.
2. **Pontua sinais de host de ferramenta**: múltiplos profiles OCI de tenancies distintas, hostname com bastion/jump/wise/monitor/zabbix/relatorio/mgmt, presença de OCI CLI sem SGBD local.
3. **Lista tudo o que encontrou** antes de qualquer escolha: todas as instâncias Oracle (oratab + processos órfãos), todos os profiles OCI com região e tenancy, todos os crontabs por usuário, todos os diretórios candidatos a repositório (descobertos por varredura de cron, mounts e filesystem, não por lista fixa).
4. **Cruza a tenancy real da própria VM** (metadata service da OCI, sem credencial) com a tenancy do profile escolhido, e exige confirmação explícita em caso de divergência.
5. **Confere o nome do cliente** contra hostname, nome da instância OCI e nomes de profiles, com match bidirecional, e alerta quando não há correspondência.
6. **Valida a autenticação do profile** OCI antes de coletar, para não gerar evidência vazia.
7. **Alerta situações que mudam a interpretação do backup**: RAC/Clusterware (job pode rodar em outro nó), dbcli/dbaascli (backup gerenciado pela OCI e não por cron), containers com banco (coleta não entra no container), cron inacessível pelo usuário atual.
8. **Exibe o plano completo e pede confirmação** antes de executar, e registra todos os alertas no `resultado_final.txt` e no `resultado.json`.

Navegação: setas ou j/k, ESPAÇO marca em listas múltiplas, `a` marca todos, `n` desmarca, ENTER confirma. Sem terminal interativo, o script usa padrões conservadores.

## Modo manual (módulos individuais)

Todos os scripts são **somente leitura** e seguros para produção. Nenhum deles altera banco, servidor ou OCI. Nenhum deles armazena senha.

## Ordem de execução

| # | Script | Onde rodar | Quando usar |
|---|--------|------------|-------------|
| 1 | `01_coleta_linux_geral.sh` | Cada servidor Linux do escopo | Sempre (descobre cron, timers, scripts, destinos) |
| 2 | `02_coleta_oracle.sh` | Servidor Oracle, usuário `oracle` | Se houver Oracle Database |
| 3 | `03_coleta_sqlserver_linux.sh` | Servidor SQL Server on Linux | Se houver SQL Server em Linux |
| 4 | `04_coleta_sqlserver_windows.ps1` | Servidor Windows (PowerShell admin) | Se houver SQL Server/Veeam em Windows |
| 5 | `05_coleta_oci.sh` | Servidor central com OCI CLI | Se o cliente tiver OCI (inclui backups de boot/block volumes das VMs OCI) |
| 6 | `06_coleta_veeam_vbr.ps1` | Servidor Veeam B&R (PowerShell admin) | Se houver Veeam: jobs, retenção, repositórios, imutabilidade (hardened/SOBR), Backup Copy/Tape, sessões 14 dias e VMs protegidas |
| 7a | `07_coleta_hypervisor_windows.ps1` | Host Hyper-V ou máquina com PowerCLI | Inventário de VMs Hyper-V/VMware + snapshots antigos, para cruzar com os jobs e achar VMs sem proteção |
| 7b | `07_coleta_hypervisor_linux.sh` | Host Proxmox/PBS/KVM (root) | Jobs vzdump, retenção (prune), verify/sync do PBS, VMs sem backup, snapshots libvirt |
| 8 | `08_coleta_cloud_outras.sh` | Servidor central com az/aws CLI | Se houver VMs em Azure (Recovery Services Vault) ou AWS (AWS Backup, EBS snapshots, DLM) |
| 8b | `10_coleta_oracle_windows.ps1` | Servidor Windows com OracleService* (PowerShell admin, grupo ORA_DBA) | Equivalente Windows do 02 (RMAN, 35 dias, archive, FRA, Data Guard, Data Pump). Chamado automaticamente pelo orquestrador |
| 9 | `09_coleta_evidencias_restore.sh` | Servidor onde a clonagem/restauração executa | Evidências de teste de restauração (Anexo I) com descoberta automática: cron e scripts chamados, varredura por conteúdo e `v$rman_status` dos bancos locais. Classifica BACKUP_RMAN x ACTIVE_DATABASE x DATAPUMP x SQLSERVER x POSTGRESQL (pg_restore) x MYSQL (xtrabackup/mariabackup/myloader) x RESTORE_VALIDATE. RPO/RTO acordados ficam A DEFINIR; os observados no ambiente vão para Observações. No wizard: modo completo ou "somente evidências" |
| 11 | `11_coleta_postgresql.sh` | Servidor PostgreSQL (postgres, root ou sudo) | Bancos e tamanho, WAL/archive e janela de recuperação ponto no tempo, `pg_stat_archiver`, replicação/standby e atraso, slots, pgBackRest/Barman/WAL-G, `pg_cron` e dumps/basebackups em disco. Fora do padrão: `WISEDB_PG_CONN="host=... user=..."` |
| 12 | `12_coleta_mysql.sh` | Servidor MySQL/MariaDB (root/unix_socket, sudo ou usuário de leitura) | Binlog e janela de PITR, bancos e tabelas MyISAM, replicação, Galera, criptografia, xtrabackup/mariabackup e dumps em disco. Usuário de leitura: `WISEDB_MY_USER=leitura` |
| 10 | `99_sanitizar_e_empacotar.sh` | Onde estiver a pasta de coleta | Sempre, antes de enviar |

## Exemplo completo (cliente com Oracle + SQL Server on Linux + OCI)

```bash
# No servidor Oracle (como oracle):
bash 01_coleta_linux_geral.sh /u02/Backup_Fisico /u02/Backup_Logico
bash 02_coleta_oracle.sh

# No servidor SQL Server (como usuário do serviço):
bash 01_coleta_linux_geral.sh /backup/database
bash 03_coleta_sqlserver_linux.sh localhost,1433 usr_leitura_wisedb

# No servidor central OCI CLI:
bash 05_coleta_oci.sh --profile CLIENTE01 --region sa-saopaulo-1 \
     --tenancy ocid1.tenancy.oc1..xxxx --bucket Backup


# No servidor Veeam B&R (VMs on-premises):
powershell -ExecutionPolicy Bypass -File .\06_coleta_veeam_vbr.ps1

# No hypervisor (para achar VMs sem proteção):
powershell -ExecutionPolicy Bypass -File .\07_coleta_hypervisor_windows.ps1 -VCenter vcenter01.dominio
bash 07_coleta_hypervisor_linux.sh   # Proxmox/PBS/KVM

# VMs em outras clouds:
bash 08_coleta_cloud_outras.sh azure
bash 08_coleta_cloud_outras.sh aws PERFIL sa-east-1

# Sanitizar e empacotar cada pasta gerada:
bash 99_sanitizar_e_empacotar.sh ./coleta_oraprod_20260901
```

## O que o RESUMO entrega para a política (digest v2.5)

Além das seções por tecnologia, o RESUMO traz:

- **INDICADORES 3-2-1-1-0**: para cada critério, os indícios a favor e contra encontrados na coleta e uma situação sugerida (ATENDE para confirmar, PARCIAL, NÃO ATENDE, NÃO EVIDENCIADO). É indício, não veredito: a IA valida contra as seções antes de usar.
- **`RESUMO_<cliente>_<host>.json`**: o mesmo conteúdo dos indicadores e dos alertas em formato estruturado, para alimentar a aba 3.CONFORMIDADE do Painel.
- Campos da política que antes ficavam sem evidência: retenção real x documentada (Oracle), criptografia (TDE, peças cifradas, `encryptor_type`, criptografia do Veeam e da chave do bucket), rotinas de verificação (VALIDATE, CHECKDB, health check), monitoramento (notificação nos scripts, agente Zabbix, container de relatório), backup do catálogo da ferramenta (configuração do Veeam) e lacuna de log do SQL Server.

## Complementos não estruturados (enviar junto, sem tratar)

- Política de backup anterior do cliente (qualquer versão).
- Relatórios semanais/mensais de backup mais recentes.
- Prints de consoles (Veeam, OCI, ferramenta de backup) com data visível.
- Anexo I de testes de restauração preenchidos, se existirem.
- Informações verbais: escrever em texto livre com **quem informou e quando**.
- RPO/RTO acordados com o cliente, se existirem.

## Regras de segurança

1. Nunca digitar senha dentro de script ou arquivo. Os scripts pedem senha interativamente quando inevitável (sqlcmd) e não a gravam.
2. Rodar sempre o `99_sanitizar_e_empacotar.sh` antes de enviar.
3. Revisar visualmente o pacote: se sobrar qualquer credencial, remover manualmente.
