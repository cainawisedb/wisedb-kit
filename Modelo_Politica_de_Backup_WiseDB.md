# MODELO | POLÍTICA DE BACKUP - PADRÃO WiseDB (estrutura v4.0)

> **Como usar este modelo (instruções para a IA):**
> 1. Preencha apenas com informações sustentadas pelas evidências fornecidas. **Nunca invente** horário, retenção, RPO, RTO, destino, ferramenta, versão, responsável ou teste.
> 2. Toda informação sem evidência recebe uma classificação explícita: **CONFIRMADO / INFORMADO / INFERIDO / A CONFIRMAR / NÃO IDENTIFICADO / INCONSISTÊNCIA / DESATUALIZADO**.
> 3. Hierarquia de evidências em caso de conflito: configuração atual > evidência operacional (relatórios/logs) > documentação > informação verbal.
> 4. Considere a data de cada evidência. Divergência entre documentos de períodos diferentes pode ser mudança de ambiente, não erro: registre no Controle de Mudança.
> 5. Relatórios provam apenas o período analisado. Escreva "No período X a Y foram observadas N execuções", nunca uma afirmação permanente.
> 6. RPO/RTO sem definição formal = "A combinar com o cliente". Pode-se registrar o RPO tecnicamente observado (ex.: archivelog a cada 30 min), diferenciando-o do RPO acordado.
> 7. Gaps não são escondidos: ausência de teste de restore, de cópia imutável ou de off-site aparece no documento e na análise 3-2-1-1-0.
> 8. Não usar o caractere "—" em texto corrido; usar vírgula ou ponto.
> 9. Placeholders estão entre `{{ }}`. Placeholder não preenchido permanece visível para revisão humana, nunca é removido silenciosamente.

---

**Capa**

Cliente: {{NOME_CLIENTE}} | {{dd/mm/aaaa}}

"Na era digital, os dados não são apenas um ativo; são a fortaleza. Esta política é o alicerce sobre o qual nossa resiliência é construída."

Versão {{X.Y}} – {{Mês/Ano}}

"Este documento é de autoria da Wise Database Solutions e deve ser utilizado para uso exclusivo de {{NOME_CLIENTE}}. Este poderá realizar as alterações que achar conveniente. Sendo vedada a cópia parcial ou integral de seu conteúdo original para utilização, divulgação ou publicação em outras empresas."

---

## 1. Objetivo

Promover segurança e continuidade do negócio de {{NOME_CLIENTE}}, estabelecendo critérios que orientem a guarda dos dados e sua eventual restauração em casos de falhas dos recursos computacionais, perdas por erro humano, ataques externos, catástrofes naturais ou outras ameaças.

A fim de assegurar a proteção dos dados eletrônicos, este documento apresenta a política de backup e restauração, onde se estabelecem responsabilidades, procedimentos, serviços de negócio e serviços de tecnologia necessários para a sua implementação e manutenção.

## 2. Definição das responsabilidades

### 2.1 Analista de Backup
Responsável pela configuração, execução, monitoramento e testes de backup e restauração. {{texto padrão WiseDB: manter tarefas/JOBs, configurar ferramenta, testar backup e restauração, notificações e relatórios, tratar falhas, comunicar ocorrências ao analista de recursos}}

### 2.2 Analista de Recursos
Responsável pela administração dos ativos de TIC necessários à política. {{texto padrão WiseDB: disponibilidade dos recursos, mitigação de riscos, controle de acesso, comunicação de incidentes, atualizações de segurança}}

### 2.3 Analista Técnico
Detém o conhecimento do ambiente que sustenta o serviço de TI. {{texto padrão WiseDB: apoio à decisão de restauração, validação do ambiente recuperado, melhoria contínua}}

### 2.4 Requisitante
Pessoa com prerrogativa de solicitar backups, restaurações e recuperações. {{texto padrão WiseDB: compreender impactos, comunicar usuários finais}}

## 3. Nosso Modelo Ideal de Backup

Modelo 3-2-1-1-0 como política oficial e ideal: 3 cópias dos dados, 2 mídias diferentes, 1 cópia off-site, 1 cópia imutável, 0 falhas nos testes de recuperação. Backups lógicos (metadados, schemas críticos) como prática indispensável. Testes recorrentes obrigatórios de: recuperação de dados, verificação da cópia imutável e checagem da cópia off-site.

**Aderência deste cliente ao modelo (preencher com base nas evidências):**

| Critério | Esperado | Encontrado | Evidência | Status |
|---|---|---|---|---|
| 3 cópias | Sim | {{ }} | {{fonte + data}} | {{CONFIRMADO/...}} |
| 2 mídias diferentes | Sim | {{ }} | {{ }} | {{ }} |
| 1 cópia off-site | Sim | {{ }} | {{ }} | {{ }} |
| 1 cópia imutável | Sim | {{ }} | {{ }} | {{ }} |
| 0 falhas em testes de restore | Sim | {{ }} | {{ }} | {{ }} |
| Backup lógico | Sim | {{ }} | {{ }} | {{ }} |

## 4. Equipe Envolvida

| Nome | E-mail | Descrição |
|---|---|---|
| {{ }} | {{ }} | {{Gerente de TI - Cliente}} |
| {{ }} | {{ }} | {{Gestão de Operação - WiseDB}} |
| {{ }} | {{ }} | {{DBA - WiseDB}} |

## 5. Serviços de TI assegurados por esta política

> Repetir o bloco 5.x para cada serviço (Oracle Database, SQL Server, MariaDB/MySQL, PostgreSQL, Compute Instances OCI, etc.).

### 5.x Serviço de TI: SGBD - {{Oracle Database | SQL Server | ...}}

**Informações sobre o servidor de banco de dados:**

| Campo | Valor | Classificação |
|---|---|---|
| Hostname / IP | {{ }} | {{ }} |
| Sistema operacional | {{ }} | {{ }} |
| Nome das instâncias | {{ }} | {{ }} |
| Nome dos bancos de dados | {{ }} | {{ }} |
| DBID (Oracle) | {{ }} | {{ }} |
| Fabricante / Edição / Versão | {{ }} | {{ }} |
| Analista técnico | {{Contrato de apoio - WiseDB}} | |
| Environment | {{Produção/Homologação}} | {{ }} |
| Política de backup dos discos do servidor | {{se aplicável}} | {{ }} |

**Procedimento de Backup Físico ({{bases}}):**

| Campo | Valor |
|---|---|
| Environment | {{ }} |
| Objetivo | Backup físico com intuito de recuperação de desastre |
| Analista de backup | {{ }} |
| Analista de recurso | {{ }} |
| Requisitantes - Backup / Recuperação | {{ }} |
| Tempo de retenção | {{separar: local / cloud / off-site; retenção efetiva se houver dependência L0/L1}} |
| Origem | {{caminhos dos datafiles}} |
| Destinos (Repositórios) | {{local + bucket/compartilhamento, com tenancy/compartment quando OCI}} |
| Procedimentos de backup | {{RMAN via crontab / Maintenance Plan / Veeam / etc.}} |
| Periodicidade dos backups | {{tipo + dia + hora, exatamente como comprovado}} |
| Procedimentos de recuperação | {{fluxo padrão Requisitante/Analista de Backup/Analista Técnico}} |
| RTO | {{valor ou "A combinar com o cliente"}} |
| RPO | {{valor ou "A combinar com o cliente"}} |
| Criptografia | {{em trânsito/repouso, ou "Não identificado"}} |
| Backup do catálogo/controlfile | {{Oracle: CONTROLFILE AUTOBACKUP ON/OFF + destino; outras ferramentas: backup do catálogo/configuração, ou "Não identificado"}} |
| Monitoramento e alertas | {{ex.: relatório semanal WiseDB, alertas automáticos de falha, ou "Não identificado"}} |
| Periodicidade dos testes | {{valor ou "Não definido"}} |
| Observações | {{retenções distintas, janelas de pausa, notas de risco como dependência de Full expurgado}} |

**Procedimento de Backup Lógico ({{bases}}):** {{mesma tabela, objetivo "exportar/importar dados e/ou definições de objetos", quando existir}}

### 5.y Serviço de TI: Compute Instances OCI (políticas gerenciadas pela OCI)

| Instance name | Compartment | Política de Backup | Retenção |
|---|---|---|---|
| {{ }} | {{ }} | {{Gold/Silver/Bronze/Custom}} | {{ }} |

### 5.z Serviço de TI: Máquinas Virtuais ({{Veeam Backup & Replication | Proxmox/PBS | Hyper-V | VMware | OCI | Azure | AWS}})

**Informações sobre a plataforma de virtualização e a ferramenta de backup:**

| Campo | Valor | Classificação |
|---|---|---|
| Hypervisor / Cloud | {{VMware vSphere x.x / Hyper-V / Proxmox VE x.x / OCI / Azure / AWS}} | {{ }} |
| Ferramenta de backup | {{Veeam B&R x.x / vzdump+PBS / Azure Backup / AWS Backup / política OCI}} | {{ }} |
| Servidor de backup | {{hostname / IP}} | {{ }} |
| Analista técnico | {{ }} | |

**Procedimento de backup das VMs:**

| Campo | Valor |
|---|---|
| Environment | {{ }} |
| Objetivo | Backup de imagem das VMs com intuito de recuperação de desastre |
| VMs protegidas | {{lista, conforme jobs/itens protegidos comprovados}} |
| Jobs / Políticas | {{nome do job Veeam, plano AWS Backup, política Azure/OCI, job vzdump}} |
| Tipo | {{Full / Incremental / Synthetic Full / Snapshot}} |
| Periodicidade | {{dia + hora, exatamente como comprovado}} |
| Retenção | {{pontos ou dias; GFS semanal/mensal/anual quando houver}} |
| Repositório primário | {{repositório/datastore/vault/bucket}} |
| Cópia secundária / off-site | {{Backup Copy Job, SOBR Capacity Tier, sync PBS, cópia cross-region, ou "Não identificado"}} |
| Imutabilidade | {{hardened repository X dias / object lock / vault lock / retention rule, ou "Não identificado"}} |
| Procedimentos de recuperação | {{fluxo padrão}} |
| RTO / RPO | {{valores ou "A combinar com o cliente"}} |
| Periodicidade dos testes | {{valor ou "Não definido"}} |
| Observações | {{ex.: execução observada no período X a Y: N sucessos, N falhas}} |

**VMs identificadas SEM proteção (cruzamento inventário x jobs):**

| VM | Hypervisor/Cloud | Situação | Risco/Justificativa |
|---|---|---|---|
| {{ }} | {{ }} | Sem job de backup | {{registrar na seção 6 se for exceção formal}} |

**Nota obrigatória:** snapshots e checkpoints de hypervisor não são backup. Se forem encontrados snapshots antigos, registrar como risco.

## 6. Serviços de TI NÃO assegurados por esta política

| Campo | Valor |
|---|---|
| Hostname / IP | {{ }} |
| Instâncias/Bases | {{ }} |
| Justificativa | {{ex.: tempdb recriada a cada restart; homologação; base descontinuada}} |
| Risco registrado | {{quando aplicável}} |

## 7. Procedimento de Testes

{{Texto padrão WiseDB sobre testes periódicos, registro no Anexo I, comunicação de imprevistos e agendamento do próximo teste.}}

**Cronograma de testes proposto:**

| Escopo do Teste | Data | Plano de Ação |
|---|---|---|
| {{Database}} | {{dd/mmm/aaaa}} | {{objetivo, medição de RPO/RTO, escopo excluído}} |

> Nota interna WiseDB (não vai para o cliente): antes de fixar qualquer data de teste de restauração, validar a disponibilidade no calendário compartilhado de janelas de teste, para não sobrepor janela já agendada por outro cliente.

**IMPORTANTE:** Independente da periodicidade dos testes, todo procedimento de backup descrito neste documento deve ter um histórico de pelo menos 1 (um) teste de recuperação realizado com sucesso. A inexistência deste teste deve ser considerada como um risco.

## 8. Recomendações

- Toda alteração nos procedimentos operacionais de backup deve ser registrada imediatamente neste documento.
- Toda inclusão, alteração ou descontinuidade de serviços de negócio ou de TI deverá ser refletida nesta política.
- A inclusão de novos ambientes deverá ser avaliada; se não coberto, documentar justificativa e riscos.
- {{Recomendações específicas derivadas dos gaps encontrados neste cliente.}}

### 8.1 Recomendação Estratégica: Plano de Recuperação de Desastres (DR)

Um backup recupera dados. Um plano de DR recupera o negócio. {{Texto padrão WiseDB sobre DR, BIA e testes periódicos.}}

### 8.2 Vulnerabilidades e inconformidades identificadas e plano de adequação

Resultado da varredura de segurança e conformidade do backup (módulo 13 do kit de coleta, servidores de banco e de backup) consolidado com os indicadores 3-2-1-1-0. Cada item mantém o ID gerado pela coleta (VUL-xxx), para rastrear a evidência e a evolução entre versões desta política.

| ID | Severidade | Categoria | Inconformidade | Evidência (fonte e data) | Impacto para o negócio | Ação recomendada | Prazo sugerido |
|---|---|---|---|---|---|---|---|
| {{VUL-001}} | {{Crítico}} | {{Ransomware}} | {{ }} | {{ }} | {{ }} | {{ }} | {{Imediato / 30 / 90 / 180 dias}} |

Regras de preenchimento: copiar os itens da seção VULNERABILIDADES E INCONFORMIDADES do RESUMO (ou de MATRIZ_VULNERABILIDADES.tsv), sem criar item sem evidência; severidade Crítico e Alto sempre listados com evidência e ação; Médio listado; Baixo e Informativo agrupados em uma linha final. Linguagem de plano de evolução, não de falha. Sem nome de produto ou fornecedor neste documento: a solução técnica vai na proposta comercial.

Prazos de referência: Crítico = imediato (até 30 dias); Alto = até 90 dias; Médio = até 180 dias; Baixo e Informativo = próximo ciclo de revisão.

## 9. Evidências de backups

> Organizar por tipo, com print/output identificado por data de coleta:

- 9.1 Backups físicos ({{RMAN/nativo}}) do SGBD {{ }}: localmente / off-site / remotamente
- 9.2 Backups lógicos ({{DATAPUMP/dump}}) do SGBD {{ }}: localmente / off-site
- 9.3 Backups físicos do SGBD {{ }}: localmente / off-site
- 9.4 {{Snapshots de boot volumes OCI, quando aplicável}}
- 9.5 Backups de VMs ({{Veeam/vzdump/Azure/AWS}}): jobs configurados, sessões recentes, repositórios e imutabilidade

## 10. Dicionário de Termos

{{Texto padrão WiseDB: Serviço de Negócio, Serviço de TI, Full, Diferencial, Incremental, Incremental Merge, Backup Lógico, Clientes de Backup, Recuperação de Desastre, Mídia, Retenção, Objeto, Tarefa de Backup, TIC, DTI, SGBD.}}

## 11. Validação e Aprovação

**Validado tecnicamente por:**

| Nome | Data |
|---|---|
| {{ }} | {{ }} |

**Aprovado por:**

| Nome | Data |
|---|---|
| {{ }} | {{ }} |

## 12. Controle de Mudança

| Versão | Data | Responsável | Modificação |
|---|---|---|---|
| {{1.0}} | {{ }} | {{ }} | Criação do documento |
| {{X.Y}} | {{ }} | {{ }} | {{descrever também mudanças de AMBIENTE detectadas, não só do texto}} |

## 13. ANEXO I - Registro de testes | Modelo

| Campo | Valor |
|---|---|
| Serviço de negócio | |
| Serviço de TI | |
| Responsável pela execução | |
| Responsável pela validação | |
| Tamanho na origem | |
| Tamanho no destino | |
| Tempo total previsto | |
| Data/Hora início | |
| Data/Hora fim | |
| Tempo total real | |
| Dentro do tempo previsto (Sim/Não) | |
| Teste efetivo (Sim/Não) | |
| Data do próximo teste | |
| Observações | |

---

## APÊNDICE INTERNO (não vai para o cliente): saídas obrigatórias da IA junto com a política

1. **Matriz de Backup:** Serviço | Servidor | Banco | Tipo | Frequência | Horário | Origem | Destino | Retenção | Off-site | Imutável | Evidência.
2. **Matriz de Evidências:** Informação | Valor | Fonte | Data | Nível de evidência | Status.
3. **Inconsistências:** política x configuração x execução observada, com período de cada fonte e possível explicação.
4. **Gaps e Riscos:** Gap | Evidência | Impacto | Risco (Crítico/Alto/Médio/Baixo/Informativo) | Recomendação.
5. **Pendências:** somente o que realmente não foi obtido, com o comando/procedimento para obter.
6. **Insumo comercial (uso interno WiseDB, nunca no documento do cliente):** Oportunidade | Prioridade (P1 a P4) | Achados VUL-xxx que a sustentam | Solução de referência | Argumento de valor (risco evitado). Fonte: seção INSUMO COMERCIAL do RESUMO e OPORTUNIDADES_COMERCIAIS_INTERNO.txt. Citar apenas parceiros e serviços reais da WiseDB.
