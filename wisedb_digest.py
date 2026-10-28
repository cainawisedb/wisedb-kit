#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
wisedb_digest.py - WiseDB | Gera RESUMO compacto da coleta de backup.

Le a pasta de coleta completa e produz um digest de ~150 linhas, pensado para
ser copiado da tela e colado em uma IA junto com o Modelo da Politica.
Os arquivos brutos completos permanecem no pacote .tar.gz.

Uso: python3 wisedb_digest.py <pasta_coleta> <cliente> <papel_host> [saida]
Compativel com Python 3.6+ (sem f-strings aninhadas).

Versao 2.6 (outubro/2026)
  [NOVO]      VULNERABILIDADES E INCONFORMIDADES: matriz unica com ID estavel
              (VUL-xxx), severidade, categoria, pilar 3-2-1-1-0, evidencia,
              impacto e acao. Consolida o modulo 13 (Linux/Windows, todos os
              hosts do pacote), os alertas automaticos com mapeamento conhecido
              e os criterios 3-2-1-1-0 nao atendidos, sem repetir a mesma chave.
  [NOVO]      INSUMO COMERCIAL (interno): achados agrupados por oportunidade de
              adequacao, com prioridade e solucao de referencia. Arquivos
              MATRIZ_VULNERABILIDADES.tsv e OPORTUNIDADES_COMERCIAIS_INTERNO.txt.
Versao 2.5 (outubro/2026)
  [NOVO]      Secoes POSTGRESQL (modulo 11), MYSQL/MARIADB (modulo 12) e NUVEM
              (AWS/GCP/Azure, modulo 08), que antes nao entravam no RESUMO.
  [NOVO]      Oracle: retencao real x RETENTION POLICY, TDE, VALIDATE,
              corrupcao, atraso de standby, Dbvisit; backup FULL sem nivel.
  [NOVO]      SQL Server: lacuna de log, restores (teste), CHECKDB, paginas
              suspeitas, backups danificados, destino VDI, falha de job.
  [NOVO]      Veeam: SureBackup, restauracoes, backup da configuracao,
              repositorio imutavel e falhas por job, com alertas.
  [NOVO]      OCI: FSS, Data Guard, MySQL HeatWave, OCI PostgreSQL, retention
              lock de volume backup, CLI desatualizado e Recovery Service via
              raw-request (JSON camelCase).
  [NOVO]      INDICADORES 3-2-1-1-0: pre-apuracao por criterio com os indicios a
              favor e contra (nao e veredito; a IA classifica). Mesmo conteudo
              em <RESUMO>.json para alimentar a aba 3.CONFORMIDADE do Painel.

Versao 2.4 (outubro/2026)
  [CORRIGIDO] Windows: os.uname() inexistente derrubava o digest (RESUMO nunca
              era gerado em Windows).
  [NOVO]      Secao ESCOPO DECLARADO NO WIZARD (exclusoes, justificativas,
              alertas, sudo, coleta incompleta).
  [CORRIGIDO] Retention rule com consulta falha nao vira mais "existe mas nao
              travada"; lifecycle ilegivel vira "nao evidenciado".
  [NOVO]      Cross-region lido tambem das regioes de destino (51_*).

Versao 2.3 (setembro/2026)
  [ALTERADO]  RPO/RTO acordados: A DEFINIR; observado vem do modulo 09.

Versao 2.2 (setembro/2026)
  [NOVO]      Secao EVIDENCIAS DE RESTAURACAO (Anexo I), lida do modulo 09
              (09_restore/anexo_I_evidencias.txt). Alertas do modulo 09 entram
              na lista de ALERTAS AUTOMATICOS.

Versao 2.1 (setembro/2026)
  [CORRIGIDO] Resolucao de pasta: o wizard passa a pasta de trabalho
              (wisedb_coleta_<host>_<data>) mas os coletores gravam em
              <trabalho>/coleta_<host>_<data>/. Antes o glob voltava vazio e o
              RESUMO saia sem nenhuma secao e sem nenhum alerta.
  [NOVO]      Alerta quando o digest NAO encontra as pastas de coleta, para
              nunca mais existir RESUMO silenciosamente vazio.
  [CORRIGIDO] Regex de falhas do RMAN passa a reconhecer tipos com espaco
              (DB INCR, DB FULL, DATAFILE INCR, ARCHIVED LOG).
  [NOVO]      Alerta de RETENTION POLICY NONE / REDUNDANCY 1 e de RMAN-06525.
  [NOVO]      Alerta de ausencia de backup nivel 0 nos ultimos 35 dias.
  [NOVO]      Secao e alertas de backup logico (Data Pump), distinguindo
              "nao coletado" de "nao existe".
  [NOVO]      Alerta de cron de sistema inacessivel (Permission denied).
  [NOVO]      Alerta de credencial embutida em script (valor ja mascarado).
  [NOVO]      Alerta quando a coleta OCI nao esta no pacote.
  [CORRIGIDO] Linhas de df e mount deixavam de ser filtradas e apareciam como
              "agendamento de cron"; a deteccao agora exige os 5 campos do cron
              e reconhece datapump, dbaascli e export como palavras-chave.
  [CORRIGIDO] O restante do titulo do prompt SQL nao entra mais como dado, e o
              corte de linha passou de 100 para 118 colunas para nao truncar as
              tabelas do RMAN.
"""
import os, re, sys, glob, socket, datetime, json

raiz    = os.path.abspath(sys.argv[1])
cliente = sys.argv[2] if len(sys.argv) > 2 else "NAO_INFORMADO"
papel   = sys.argv[3] if len(sys.argv) > 3 else "?"
saida   = sys.argv[4] if len(sys.argv) > 4 else os.path.join(raiz, "RESUMO.txt")

L = []      # linhas do resumo
ALERTAS = []
# Indicios por criterio do 3-2-1-1-0. "a" = a favor, "c" = contra/nao evidenciado.
IND = dict((k, {"a": [], "c": []}) for k in
           ("COPIAS", "MIDIAS", "OFFSITE", "IMUTAVEL", "TESTES", "LOGICO"))
LOCAIS = set()   # locais distintos onde ha copia de backup (para o criterio 3)


def ind(crit, favor, texto):
    lst = IND[crit]["a" if favor else "c"]
    if texto not in lst:
        lst.append(texto)


def num(x, padrao=0):
    try:
        return int(float(x))
    except Exception:
        return padrao

# Tipos de input_type do v$rman_backup_job_details (alguns tem espaco no nome)
TIPOS_RMAN = (r'ARCHIVELOG|ARCHIVED LOG|DB FULL|DB INCR|DB PARTIAL|'
              r'DATAFILE FULL|DATAFILE INCR|SPFILE|CONTROLFILE|RECVR AREA')


def add(s=""):
    L.append(s)


def sec(t):
    add("")
    add("== " + t + " " + "=" * max(0, 62 - len(t)))


def ler(caminho):
    try:
        with open(caminho, encoding="utf-8", errors="replace") as f:
            return f.read()
    except Exception:
        return ""


# ---------------------------------------------------------------------------
# Resolucao da pasta base de evidencias.
# O wizard chama este script com a pasta de trabalho, enquanto os coletores
# gravam em ./coleta_<host>_<data>/ relativo ao diretorio corrente. Aceitamos
# as duas formas, e ainda uma busca recursiva como ultimo recurso.
# ---------------------------------------------------------------------------
def tem_evidencia(d):
    return (os.path.isdir(os.path.join(d, "01_linux")) or
            os.path.isdir(os.path.join(d, "02_oracle")) or
            os.path.isdir(os.path.join(d, "03_sqlserver")) or
            os.path.isdir(os.path.join(d, "04_windows")) or
            os.path.isdir(os.path.join(d, "09_restore")) or
            os.path.isdir(os.path.join(d, "11_postgresql")) or
            os.path.isdir(os.path.join(d, "12_mysql")))


def bases_com_evidencia(r):
    """Todas as pastas de evidencia sob a raiz, nao apenas a primeira.

    A versao anterior retornava UMA pasta. Quando a pasta de trabalho continha
    a coleta de mais de um host, por exemplo coleta_bastion-database_* e
    coleta_databaseprod_*, o digest descrevia apenas a que vinha primeiro em
    ordem alfabetica e o RESUMO do outro host saia sem nenhuma secao de
    evidencia, dando a impressao de host sem backup. Agora enumeramos todas e
    avisamos quando ha mais de uma.
    """
    achadas = []
    if tem_evidencia(r):
        achadas.append(r)
    for d in sorted(glob.glob(os.path.join(r, "coleta_*"))):
        if (os.path.isdir(d) and not os.path.basename(d).startswith("coleta_oci_")
                and tem_evidencia(d) and d not in achadas):
            achadas.append(d)
    if not achadas:
        for atual, dirs, _ in os.walk(r):
            if any(x in dirs for x in ("01_linux", "02_oracle", "03_sqlserver", "04_windows", "09_restore",
                                       "11_postgresql", "12_mysql")):
                achadas.append(atual)
    return achadas


BASES = bases_com_evidencia(raiz)
# os.uname() nao existe no Python para Windows: o RESUMO nunca era gerado la.
host_local = (socket.gethostname() or "").split(".")[0].lower()


def escolhe_base(cands):
    """Prioriza a pasta do host onde o digest esta rodando.

    Sem isso, com duas coletas na mesma pasta, o RESUMO podia descrever o
    ambiente de um host e levar o nome de outro no cabecalho.
    """
    if not cands:
        return raiz
    for d in cands:
        if host_local and host_local in os.path.basename(d).lower():
            return d
    return cands[0]


base = escolhe_base(BASES)


def ler_ev(rel):
    """Le um arquivo de evidencia procurando na pasta base e depois na raiz."""
    for d in (base, raiz):
        t = ler(os.path.join(d, rel))
        if t:
            return t
    return ""


def achar_ev(padrao):
    for d in (base, raiz):
        r = sorted(glob.glob(os.path.join(d, padrao)))
        if r:
            return r[0]
    return None


def glob_ev(padrao):
    vistos, out = set(), []
    for d in (base, raiz):
        for p in sorted(glob.glob(os.path.join(d, padrao))):
            k = os.path.realpath(p)
            if k not in vistos:
                vistos.add(k)
                out.append(p)
    return out


def bloco(txt, marca, prox_marca="###", limite=40):
    """Extrai a secao que comeca em `marca` ate a proxima marca."""
    i = txt.find(marca)
    if i < 0:
        return []
    resto = txt[i + len(marca):]
    nl = resto.find("\n")
    if nl >= 0:
        resto = resto[nl + 1:]          # ignora o restante da linha da marca
    j = resto.find(prox_marca)
    corpo = resto[:j] if j >= 0 else resto
    out = []
    for ln in corpo.splitlines():
        s = ln.rstrip()
        if not s.strip():
            continue
        if s.strip().startswith("---") or "rows selected" in s or s.startswith("PL/SQL"):
            continue
        if not out and re.match(r'^\s*\(?[A-Z]{0,3}[a-z(].*\)?$', s) and not re.search(r'\d', s) and len(s.strip()) < 60:
            continue  # resto do titulo do prompt, nao e dado
        out.append("  " + s.strip()[:118])
        if len(out) >= limite:
            out.append("  ... (truncado, ver pacote completo)")
            break
    return out


def bruto(txt, marca, prox_marca="###", limite=40):
    """Como bloco(), mas sem filtro heuristico de titulo. Usado em blocos
    cujo conteudo pode ser texto livre (ex.: output de erro do RMAN)."""
    i = txt.find(marca)
    if i < 0:
        return []
    resto = txt[i + len(marca):]
    nl = resto.find("\n")
    if nl >= 0:
        resto = resto[nl + 1:]
    j = resto.find(prox_marca)
    corpo = resto[:j] if j >= 0 else resto
    out = []
    for ln in corpo.splitlines():
        s = ln.strip()
        if not s or s.startswith("---") or "rows selected" in s:
            continue
        out.append("  " + s[:118])
        if len(out) >= limite:
            out.append("  ... (truncado, ver pacote completo)")
            break
    return out


# ============================ CABECALHO =====================================
add("#" * 70)
add("# RESUMO DE COLETA DE BACKUP - WiseDB")
add("# Cliente ......: " + cliente)
add("# Papel do host : " + papel)
add("# Pasta ........: " + os.path.basename(raiz))
if os.path.realpath(base) != os.path.realpath(raiz):
    add("# Evidencias em : " + os.path.relpath(base, raiz))
add("#" * 70)

# Escopo declarado pelo operador no wizard (v3.7 / ps1 v2.3). Sem isto a IA
# recebia bases marcadas como fora do escopo como se fossem assseguradas.
esc = ler(os.path.join(raiz, "escopo_wizard.txt"))
if esc.strip():
    sec("ESCOPO DECLARADO NO WIZARD (operador)")
    for ln in esc.lstrip("\ufeff").splitlines():
        if ln.strip():
            add("  " + ln.rstrip()[:118])
    if re.search(r'Coleta incompleta \.*: SIM', esc):
        ALERTAS.append("Coleta INCOMPLETA: um ou mais modulos falharam (ver ESCOPO DECLARADO NO WIZARD)")

if papel == "ESTACAO_COLETA_WISEDB":
    add("# NOTA: host de ferramenta WiseDB. Dados locais NAO pertencem ao cliente;")
    add("#       somente a coleta OCI abaixo e evidencia do cliente.")

def oci_dirs_recursivo(r):
    """Procura coleta_oci_* em qualquer nivel.

    A busca antiga olhava apenas a raiz e a base, e emitia "coleta OCI ausente
    neste pacote" mesmo quando a coleta existia num nivel abaixo. Esse falso
    positivo levava a politica a registrar pendencia inexistente.
    """
    achados = []
    for d in glob_ev("coleta_oci_*"):
        if os.path.isdir(d):
            achados.append(d)
    for atual, dirs, _ in os.walk(r):
        for d in dirs:
            if d.startswith("coleta_oci_"):
                p = os.path.join(atual, d)
                if p not in achados:
                    achados.append(p)
    return sorted(set(achados))


OCI_DIRS = oci_dirs_recursivo(raiz)

# Profiles distintos no mesmo pacote significam evidencia de mais de um cliente.
# Nesse caso NAO renderizamos nenhum dado OCI: exibir a coleta de um profile
# escolhido por ordem alfabetica foi exatamente o que fez o ambiente de um
# cliente aparecer no resumo de outro.
OCI_PERFIS = sorted({os.path.basename(d).replace("coleta_oci_", "").rsplit("_", 1)[0]
                     for d in OCI_DIRS})
OCI_CONTAMINADO = len(OCI_PERFIS) > 1


def glob_todas_bases(padrao):
    """Varre o padrao em TODAS as bases de evidencia, nao apenas na escolhida.

    Blocos como destino do SBT e dbcli nao podem se perder so porque o pacote
    tem mais de um host: eles descrevem o backup fisico, o dado mais critico.
    """
    vistos, out = set(), []
    for d in list(BASES) + [raiz]:
        for p in sorted(glob.glob(os.path.join(d, padrao))):
            k = os.path.realpath(p)
            if k not in vistos:
                vistos.add(k)
                out.append(p)
    return out


def ler_todas_bases(rel):
    for d in list(BASES) + [raiz]:
        t = ler(os.path.join(d, rel))
        if t:
            return t
    return ""

if not tem_evidencia(base) and not OCI_DIRS:
    ALERTAS.append("DIGEST: nao localizei 01_linux/02_oracle/03_sqlserver nem coleta_oci_* "
                   "em " + os.path.basename(raiz) + " -> RESUMO incompleto, use o resultado_final.txt")

# Pacote com mais de um host: o RESUMO descreve so um deles, e o operador precisa
# saber quais ficaram de fora para nao concluir que aquele host nao tem backup.
if len(BASES) > 1:
    outras = [os.path.basename(d) for d in BASES if d != base]
    ALERTAS.append("DIGEST: este pacote contem coleta de mais de um host. Este RESUMO descreve "
                   + os.path.basename(base) + ". Nao descrito(s) aqui: " + ", ".join(outras)
                   + " -> gere um RESUMO por host ou use o resultado_final.txt")

# Contaminacao entre clientes: mais de uma tenancy no mesmo pacote. Nunca deve
# alimentar a politica, porque parte da evidencia pertence a outro cliente.
if len(OCI_DIRS) > 1:
    perfis = sorted({os.path.basename(d).replace("coleta_oci_", "").rsplit("_", 1)[0]
                     for d in OCI_DIRS})
    if len(perfis) > 1:
        ALERTAS.append("INCONSISTENCIA DE COLETA: o pacote traz coletas OCI de profiles "
                       "diferentes (" + ", ".join(perfis) + "). Isso indica reuso de pasta de "
                       "trabalho entre clientes. NAO use este pacote para gerar politica: "
                       "identifique o profile do cliente correto e recolete em pasta limpa")

# Mesma guarda para AWS/GCP/Azure: mais de um alvo no pacote precisa ser do
# mesmo cliente (o operador confirma no wizard; aqui fica registrado).
_cl = sorted({os.path.basename(d).rsplit("_", 1)[0] for d in glob.glob(os.path.join(raiz, "coleta_cloud_*"))})
if len(_cl) > 1:
    ALERTAS.append("Pacote com mais de uma conta de nuvem publica (" + ", ".join(_cl) + "): confirmar que TODAS "
                   "pertencem ao cliente antes de usar na politica")

# ============================ 1. SERVIDOR ===================================
inv = ler_ev(os.path.join("01_linux", "inventario_geral.txt"))
if inv:
    sec("SERVIDOR")
    m = re.search(r'PRETTY_NAME="([^"]+)"', inv)
    if m: add("  SO: " + m.group(1))
    m = re.search(r'## Hostname / IPs.*?\n.*?\n.*?\n.*?\n([^\n]+)', inv, re.S)
    if m: add("  IPs: " + m.group(1).strip()[:80])
    m = re.search(r'Time zone:\s*([^\n]+)', inv)
    if m: add("  Timezone: " + m.group(1).strip())

    # Filesystems relevantes (backup/u0x)
    fs = []
    for ln in inv.splitlines():
        if re.match(r'^/dev/\S+', ln) and re.search(r'/u0|/[Bb]ackup|/bkp|/stage|/WiseDb', ln):
            c = ln.split()
            if len(c) >= 7:
                fs.append("  " + c[6] + ": " + c[2] + " total, " + c[5] + " usado")
    if fs:
        add("  Areas de backup (uso real):")
        for f in sorted(set(fs))[:8]:
            add("  " + f)
            if re.search(r'\b[0-9]%', f) and re.search(r'/[Bb]ackup', f):
                ALERTAS.append("Area de backup com uso proximo de zero (" + f.strip() + "): verificar se ha copia LOCAL")

    # Mounts de rede
    nfs = [l.strip()[:90] for l in inv.splitlines() if re.search(r'type (nfs|cifs)', l)]
    if nfs:
        add("  Mounts de rede:")
        for n in nfs[:4]: add("    " + n)

    # Cron: apenas linhas de backup
    cron = set()
    CRON5 = r'^[0-9*][0-9*/,\-]*\s+[0-9*][0-9*/,\-]*\s+\S+\s+\S+\s+\S+\s+\S'
    CHAVE = (r'backup|bkp|rman|expdp|expdb|datapump|dbaascli|dump|rsync|oci os|'
             r'veeam|bacula|restic|borg|snapshot|export')
    for ln in inv.splitlines():
        s = ln.strip()
        if re.match(CRON5, s) and re.search(CHAVE, s, re.I) and not re.search(r'type (nfs|cifs)|\s\d+%\s', s):
            cron.add(s[:118])
    if cron:
        add("  Agendamentos de backup no cron:")
        for c in sorted(cron)[:12]: add("    " + c)
    else:
        ALERTAS.append("Nenhum agendamento de backup encontrado no cron acessivel")

    # Cron de sistema inacessivel: pode haver job de backup sob root invisivel
    if re.search(r'/etc/cron[^\n]*\n[^\n]*Permission denied', inv) or \
       re.search(r'(cat|ls): .*?/etc/cron[^\n]*Permission denied', inv):
        ALERTAS.append("Cron de sistema (/etc/crontab, /etc/cron.d) inacessivel para este usuario: "
                       "reexecutar a coleta com sudo; pode haver job de backup sob root")

    scripts = glob_ev(os.path.join("01_linux", "scripts_de_backup", "*.txt"))
    if scripts:
        add("  Scripts de backup capturados (" + str(len(scripts)) + "):")
        for s in scripts[:12]:
            add("    " + os.path.basename(s)[:96])
        cred = []
        for s in scripts:
            c = ler(s)
            if re.search(r'[A-Za-z0-9_]+/\*\*\*REMOVIDO\*\*\*@', c) or \
               re.search(r'(REMOVIDO).{0,12}@', c):
                cred.append(os.path.basename(s))
        if cred:
            ALERTAS.append("Credencial embutida em script de producao (valor mascarado na coleta): " +
                           ", ".join(cred[:3])[:80] + " -> gap de seguranca, recomendar wallet/SEPS e rotacao")

    faltando = ler_ev(os.path.join("01_linux", "scripts_nao_encontrados.txt"))
    if faltando.strip():
        add("  Scripts referenciados e NAO encontrados no filesystem:")
        for ln in faltando.strip().splitlines()[:8]:
            add("    " + ln.strip()[:96])
        ALERTAS.append("Ha script referenciado no cron/wrapper que nao existe no filesystem: "
                       "rotina pode estar quebrada (ver scripts_nao_encontrados.txt)")

# ============================ 2. ORACLE =====================================
for sqlf in sorted(glob_ev(os.path.join("02_oracle", "*_sql.txt"))):
    sid = os.path.basename(sqlf).replace("_sql.txt", "")
    t = ler(sqlf)
    sec("ORACLE: " + sid)
    for marca, titulo, lim in [
        ("### IDENTIFICACAO", "Identificacao", 8),
        ("### PDBs", "PDBs", 8),
        ("### TAMANHO REAL", "Tamanho", 8),
        ("### DESTINOS DE ARCHIVE", "Destino de archive", 8),
        ("### RMAN 35 DIAS - RESUMO AGREGADO POR TIPO", "RMAN 35d por tipo", 12),
        ("### RMAN 35 DIAS - HORARIO TIPICO", "Horario tipico", 14),
        ("### RMAN - NIVEL 0 x NIVEL 1", "Nivel 0 x Nivel 1 (por dia)", 12),
        ("### RMAN - FALHAS (v$rman_backup_job_details", "FALHAS (job details)", 8),
        ("### RMAN - FALHAS (v$rman_status", "FALHAS (operacional)", 8),
        ("### ARCHIVELOG - VOLUME REAL POR DIA", "Archivelog por dia", 9),
        ("### ARCHIVELOG - MAIOR INTERVALO", "Maior gap sem archive (RPO real)", 4),
        ("### BACKUPSETS EM DISCO x SBT", "Onde as copias estao", 6),
        ("### CONTROLFILE AUTOBACKUP", "Autobackup do controlfile", 4),
        ("### DIRECTORIES", "Directories de expdp", 8),
        ("### JOBS DBMS_SCHEDULER", "Jobs do scheduler", 5),
        ("### TAMANHO (v$datafile", "Tamanho (v$datafile)", 3),
        ("### RETENCAO REAL - BACKUP DE DATAFILE", "Retencao REAL: datafile mais antigo disponivel", 8),
        ("### RETENCAO REAL - ARCHIVELOG", "Retencao REAL: archivelog mais antigo em backup", 4),
        ("### PARAMETROS QUE LIMITAM", "Parametros que limitam a recuperacao", 6),
        ("### FLASHBACK DATABASE", "Flashback e restore points", 6),
        ("### BLOCK CHANGE TRACKING", "Block change tracking", 3),
        ("### CRIPTOGRAFIA - WALLET", "Wallet/keystore TDE", 6),
        ("### CRIPTOGRAFIA E COMPRESSAO", "Pecas cifradas/comprimidas (35d)", 6),
        ("### ROTINAS DE VERIFICACAO", "VALIDATE/CROSSCHECK/DELETE (35d)", 8),
        ("### CORRUPCAO DE BLOCOS", "Corrupcao de blocos", 3),
        ("### DATA GUARD - DESTINOS", "Data Guard: destinos remotos", 6),
        ("### STANDBY - ATRASO", "Standby: atraso de aplicacao", 6),
    ]:
        b = bloco(t, marca, "###", lim)
        if b:
            add("  [" + titulo + "]")
            for ln in b: add("  " + ln)

    # Output da falha mais recente: e o que explica a causa raiz
    of = bruto(t, "### RMAN - OUTPUT DA FALHA MAIS RECENTE", "###", 12)
    if of:
        add("  [Output da falha mais recente]")
        for ln in of: add("  " + ln)

    #--- Alertas automaticos do banco -----------------------------------------
    for ln in t.splitlines():
        mm = re.match(r'^\s*(' + TIPOS_RMAN + r')\s+(\d+)\s+(\d+)\s+([1-9]\d*)\s+\d{2}/\d{2}', ln)
        if mm:
            ALERTAS.append("Backup tipo " + mm.group(1).strip() + " no " + sid + ": " +
                           mm.group(4) + " FALHAS em 35 dias (de " + mm.group(2) + " execucoes)")

    # Onde as copias realmente estao
    seg_bs = t.split("### BACKUPSETS")[-1].split("###")[0] if "### BACKUPSETS" in t else ""
    if "SBT_TAPE" in seg_bs and not re.search(r'^\s*DISK\b', seg_bs, re.M):
        ALERTAS.append(sid + ": backupsets somente em SBT (cloud), sem copia em DISK -> ponto 3-2-1")
    if seg_bs.strip() and not re.search(r'(SBT_TAPE|DISK)', seg_bs):
        ALERTAS.append(sid + ": nenhuma peca de backup nos ultimos 35 dias em nenhum device")

    # Nivel 0 nos ultimos 35 dias
    seg_n0 = t.split("### RMAN - NIVEL 0 x NIVEL 1")[-1].split("###")[0] if "### RMAN - NIVEL 0 x NIVEL 1" in t else ""
    if seg_n0.strip():
        tem_n0 = re.search(r'^\s*\d{2}/\d{2}[^\n]*?\s(0|FULL)\s+\d', seg_n0, re.M)
        if not tem_n0:
            ALERTAS.append(sid + ": nenhum backup NIVEL 0 identificado em 35 dias -> cadeia incremental "
                           "sem base recente, confirmar politica de full do provedor")

    #--- Indicadores 3-2-1-1-0 a partir de onde as pecas estao ------------------
    if "### BACKUPSETS" in t:
        if re.search(r'^\s*DISK\b', seg_bs, re.M):
            LOCAIS.add("disco local (" + sid + ")"); ind("COPIAS", True, sid + ": backupsets em disco")
        if "SBT_TAPE" in seg_bs:
            LOCAIS.add("SBT/nuvem (" + sid + ")"); ind("COPIAS", True, sid + ": backupsets em SBT (Object Storage/Recovery Service/terceiro)")
            ind("OFFSITE", True, sid + ": copia fisica fora do servidor (SBT)")
        if re.search(r'^\s*DISK\b', seg_bs, re.M) and "SBT_TAPE" in seg_bs:
            ind("MIDIAS", True, sid + ": DISK + SBT")
        elif seg_bs.strip():
            ind("MIDIAS", False, sid + ": backup fisico em um unico tipo de midia")

    def sec_txt(marca):
        # descarta o resto da linha da marca (o titulo cita VALIDATE, NO etc.)
        if marca not in t:
            return ""
        resto = t.split(marca)[-1]
        resto = resto[resto.find("\n") + 1:] if "\n" in resto else ""
        return resto.split("###")[0]

    # Retencao real x politica do RMAN (caso DBS Partner: 4-21 dias reais x 30 documentados)
    r_cfg = ler(sqlf.replace("_sql.txt", "_rman.txt"))
    mjan = re.search(r'RECOVERY WINDOW OF (\d+) DAYS', r_cfg)
    ret = sec_txt("### RETENCAO REAL - BACKUP DE DATAFILE")
    dias_dev = {}
    for dev, niv, dias in re.findall(r'^\s*(DISK|SBT_TAPE)\s+(\S+)\s+\d{2}/\d{2}/\d{4} \d{2}:\d{2}\s+(\d+)', ret, re.M):
        if niv in ("0", "FULL"):
            dias_dev[dev] = max(dias_dev.get(dev, 0), num(dias))
    if mjan and dias_dev:
        jan = num(mjan.group(1))
        maior = max(dias_dev.values())
        if maior < jan:
            ALERTAS.append(sid + ": retencao REAL do backup full/nivel 0 = " + str(maior) + " dias (" +
                           ", ".join(k + "=" + str(v) for k, v in sorted(dias_dev.items())) +
                           ") contra RECOVERY WINDOW de " + str(jan) + " dias no RMAN -> janela documentada nao e atendida")
    par = sec_txt("### PARAMETROS QUE LIMITAM")
    mk = re.search(r'control_file_record_keep_time\s+(\d+)', par)
    if mk and mjan and num(mk.group(1)) < num(mjan.group(1)):
        ALERTAS.append(sid + ": control_file_record_keep_time=" + mk.group(1) + " menor que a RECOVERY WINDOW de " +
                       mjan.group(1) + " dias: sem catalogo RMAN, registros de backup saem do controlfile antes do fim da janela")
    # TDE: backup cifrado nao restaura sem o wallet
    wal = sec_txt("### CRIPTOGRAFIA - WALLET")
    mt = re.search(r'TABLESPACES_CIFRADOS\s*\n[\s-]*\n\s*(\d+)', wal, re.I)
    if mt and num(mt.group(1)) > 0:
        ALERTAS.append(sid + ": " + mt.group(1) + " tablespace(s) cifrado(s) com TDE: o wallet/keystore precisa estar no escopo "
                       "do backup e ter copia fora do servidor (sem ele o restore falha)")
    if re.search(r'\bNO\s*$', wal, re.M) and "FULLY_BACKED_UP" in wal.upper():
        ALERTAS.append(sid + ": keystore TDE com FULLY_BACKED_UP=NO (chaves sem backup)")
    pec = sec_txt("### CRIPTOGRAFIA E COMPRESSAO")
    if re.search(r'^\s*SBT_TAPE\s+NO\b', pec, re.M):
        ALERTAS.append(sid + ": pecas de backup em SBT sem criptografia RMAN nos ultimos 35 dias")
    # Rotinas de verificacao (o "0 erros" depende de VALIDATE ou de teste)
    if "### ROTINAS DE VERIFICACAO" in t:
        ver = sec_txt("### ROTINAS DE VERIFICACAO")
        if not re.search(r'VALIDATE', ver):
            ALERTAS.append(sid + ": nenhuma execucao de VALIDATE/RESTORE VALIDATE em 35 dias (backup nunca verificado entre testes)")
        else:
            ind("TESTES", True, sid + ": VALIDATE executado em 35 dias (evidencia parcial)")
    mc = re.search(r'BLOCOS_CORROMPIDOS\s*\n[\s-]*\n\s*(\d+)', sec_txt("### CORRUPCAO DE BLOCOS"), re.I)
    if mc and num(mc.group(1)) > 0:
        ALERTAS.append("CRITICO " + sid + ": " + mc.group(1) + " bloco(s) corrompido(s) registrados em v$database_block_corruption")
    stb = sec_txt("### STANDBY - ATRASO")
    ma = re.search(r'(PHYSICAL STANDBY|LOGICAL STANDBY|SNAPSHOT STANDBY)[^\n]*?(\d+)\s*$', stb, re.M)
    if ma:
        ind("OFFSITE", True, sid + ": este banco e standby (copia em outro servidor)")
        if num(ma.group(2)) > 120:
            ALERTAS.append(sid + ": standby com atraso de " + ma.group(2) + " minutos na aplicacao (RPO de DR comprometido)")
    dg = sec_txt("### DATA GUARD - DESTINOS")
    for ln in dg.splitlines():
        if re.search(r'\b(ERROR|ORA-\d{5})', ln):
            ALERTAS.append(sid + ": destino Data Guard com erro: " + re.sub(r'\s+', ' ', ln.strip())[:110])
            break
    if re.search(r'^\s*\d+\s+VALID\s+(PHYSICAL|LOGICAL)', dg, re.M):
        ind("OFFSITE", True, sid + ": Data Guard ativo (standby remoto)")

    #--- Configuracao RMAN ----------------------------------------------------
    rmanf = sqlf.replace("_sql.txt", "_rman.txt")
    r = ler(rmanf)
    if r:
        add("  [Configuracao RMAN]")
        for pat, rot in [
            (r'CONFIGURE RETENTION POLICY[^;]+;', "Retencao"),
            (r'CONFIGURE CONTROLFILE AUTOBACKUP [A-Z]+;', "Autobackup CF"),
            (r'CONFIGURE DEFAULT DEVICE TYPE[^;]+;', "Device padrao"),
            (r"CONFIGURE DEVICE TYPE '?SBT_TAPE'?[^;]+;", "SBT"),
            (r'CONFIGURE ENCRYPTION FOR DATABASE [A-Z]+;', "Criptografia DB"),
            (r'CONFIGURE ENCRYPTION ALGORITHM[^;]+;', "Algoritmo"),
            (r'CONFIGURE ARCHIVELOG DELETION POLICY[^;]+;', "Delecao de archive"),
            (r'CONFIGURE COMPRESSION ALGORITHM[^;]+;', "Compressao"),
        ]:
            m = re.search(pat, r)
            if m: add("    " + rot + ": " + m.group(0).strip()[:95])
        if re.search(r'CONFIGURE CONTROLFILE AUTOBACKUP OFF', r):
            ALERTAS.append(sid + ": CONTROLFILE AUTOBACKUP esta OFF -> catalogo de metadados sem protecao")
        if re.search(r'CONFIGURE ENCRYPTION FOR DATABASE OFF', r):
            ALERTAS.append(sid + ": criptografia de backup desabilitada no RMAN")
        if re.search(r'CONFIGURE RETENTION POLICY TO NONE', r):
            ALERTAS.append(sid + ": RETENTION POLICY TO NONE -> nenhuma janela de recuperacao declarada "
                           "no RMAN; a retencao real depende do destino (DBRS/Object Storage), confirmar")
        m = re.search(r'CONFIGURE RETENTION POLICY TO REDUNDANCY\s+1\s*;', r)
        if m:
            ALERTAS.append(sid + ": RETENTION POLICY REDUNDANCY 1 -> apenas uma copia valida retida")
        if re.search(r'RMAN-06525', r):
            ALERTAS.append(sid + ": REPORT NEED BACKUP falhou com RMAN-06525 (retention policy none)")
        if re.search(r'RMAN-0(3002|4014|6059|6023)', r):
            ALERTAS.append(sid + ": erro RMAN registrado durante a coleta (ver *_rman.txt)")

        need = re.search(r'Report of files that must be backed up[^\n]*\n[^\n]*\n[^\n]*\n(.*?)(?:RMAN>|$)', r, re.S)
        if need:
            corpo = need.group(1).strip()
            add("    REPORT NEED BACKUP: " + ("nenhum arquivo pendente" if not corpo else corpo[:70]))
            if corpo:
                ALERTAS.append(sid + ": existem arquivos pendentes de backup na janela de retencao")

        cf = re.search(r'LIST BACKUP OF CONTROLFILE.*?(?:RMAN>|$)', r, re.S)
        if cf and re.search(r'no backup', cf.group(0), re.I):
            ALERTAS.append(sid + ": LIST BACKUP OF CONTROLFILE nao retornou backup recente do controlfile")

# ---- Backup logico (Data Pump) ---------------------------------------------
ex = ler_ev(os.path.join("02_oracle", "expdp_logs_recentes.txt"))
if ex:
    sec("BACKUP LOGICO (Data Pump)")
    corpo = [l for l in ex.splitlines() if l.strip() and not l.startswith("####")]
    for ln in corpo[:30]:
        add("  " + ln.strip()[:100])
    if len(corpo) > 30:
        add("  ... (truncado, ver pacote completo)")
    if "[SEM EVIDENCIA]" in ex:
        ALERTAS.append("Backup logico: nenhum dump ou log de expdp com menos de 8 dias nos diretorios "
                       "varridos -> classificar como NAO COLETADO / A CONFIRMAR, nao como inexistente")
        ind("LOGICO", False, "Oracle: sem dump de Data Pump recente nos diretorios varridos")
    elif re.search(r'\.dmp', ex):
        ind("LOGICO", True, "Oracle: dumps de Data Pump com menos de 8 dias")
        LOCAIS.add("dump logico em disco (Oracle)")
    if not corpo:
        ALERTAS.append("Backup logico: arquivo de evidencia vazio, o coletor nao varreu diretorio nenhum "
                       "-> revalidar informando os diretorios de dump como argumento")

dbv = ler_ev(os.path.join("02_oracle", "dbvisit_standby.txt"))
if dbv.strip():
    sec("DBVISIT STANDBY")
    for ln in [l for l in dbv.splitlines() if l.strip() and not l.startswith("####")][:15]:
        add("  " + ln.strip()[:110])
    ind("OFFSITE", True, "Dbvisit Standby presente (standby remoto)")

# ============================ 2b. POSTGRESQL ================================
for pgf in sorted(glob_ev(os.path.join("11_postgresql", "*_sql.txt"))):
    porta = os.path.basename(pgf).replace("_sql.txt", "")
    t = ler(pgf)
    sec("POSTGRESQL: porta " + porta)
    if "[ERRO] Sem conexao" in t:
        add("  Sem conexao ao cluster (ver " + os.path.basename(pgf) + ")")
        ALERTAS.append("PostgreSQL porta " + porta + ": sem conexao na coleta -> configuracao de WAL/archive, "
                       "replicacao e tamanho NAO evidenciados; recoletar como postgres/root ou com WISEDB_PG_CONN")
        continue
    m = re.search(r'PostgreSQL (\d+[\d.]*)', t)
    if m: add("  Versao: PostgreSQL " + m.group(1))
    for marca, titulo, lim in [("### BANCOS E TAMANHO", "Bancos e tamanho", 12),
                               ("### TAMANHO TOTAL", "Tamanho total (GB)", 3),
                               ("### ARCHIVER", "Archiver (pg_stat_archiver)", 4),
                               ("### REPLICACAO - STANDBYS", "Standbys conectados", 6),
                               ("### STANDBY - ATRASO", "Atraso como standby", 4),
                               ("### SLOTS DE REPLICACAO", "Slots de replicacao", 6),
                               ("### AGENDAMENTOS PG_CRON", "pg_cron", 6)]:
        bb = bruto(t, marca, "###", lim + 3)
        if not bb or any(re.search(r'\(0 rows\)', x) for x in bb):
            continue
        bb = [x for x in bb if not re.search(r'^\s*\(\d+ rows?\)\s*$', x) and not re.match(r'^[-+\s]+$', x)]
        if marca == "### STANDBY - ATRASO" and len(bb) > 1 and re.match(r'^\s*f\b', bb[1]):
            continue   # nao e standby
        if len(bb) > 1:
            add("  [" + titulo + "]")
            for ln in bb[:lim]:
                add("  " + ln[:116])
    cfg = {}
    for nome, val in re.findall(r'^\s*([a-z_]+)\s+\|\s*([^|]*?)\s*\|', t.split("### CONFIGURACAO DE WAL")[-1].split("###")[0], re.M):
        cfg[nome] = val
    add("  [Configuracao] wal_level=" + cfg.get("wal_level", "?") + " | archive_mode=" + cfg.get("archive_mode", "?") +
        " | data_checksums=" + cfg.get("data_checksums", "?"))
    if cfg.get("archive_command"): add("    archive_command: " + cfg["archive_command"][:100])
    if cfg.get("primary_conninfo"): add("    primary_conninfo (standby): " + cfg["primary_conninfo"][:90])
    if cfg.get("archive_mode", "") == "off":
        ALERTAS.append("PostgreSQL porta " + porta + ": archive_mode=off -> sem archive de WAL, recuperacao so ate o "
                       "ultimo dump/basebackup (sem ponto no tempo); RPO = intervalo entre backups")
    arq = t.split("### ARCHIVER")[-1].split("###")[0] if "### ARCHIVER" in t else ""
    ma = re.search(r'^\s*\d+\s*\|[^|]*\|([^|]*)\|\s*(\d+)\s*\|[^|]*\|([^|]*)\|', arq, re.M)
    if ma and num(ma.group(2)) > 0 and ma.group(3).strip() and ma.group(3).strip() > ma.group(1).strip():
        ALERTAS.append("PostgreSQL porta " + porta + ": archive de WAL FALHANDO (ultima falha " + ma.group(3).strip()[:16] +
                       " posterior ao ultimo arquivamento com sucesso)")
    slots = t.split("### SLOTS DE REPLICACAO")[-1].split("###")[0] if "### SLOTS" in t else ""
    for nome in re.findall(r'^\s*(\S+)\s*\|\s*(?:physical|logical)\s*\|[^|]*\|\s*f\s*\|', slots, re.M):
        ALERTAS.append("PostgreSQL porta " + porta + ": slot de replicacao '" + nome + "' INATIVO retem WAL e pode encher o disco")
    stb = t.split("### STANDBY - ATRASO")[-1].split("###")[0] if "### STANDBY - ATRASO" in t else ""
    mm = re.search(r'^\s*t\s*\|\s*(?:(\d+) days? )?(\d+):(\d+)', stb, re.M)
    if mm:
        ind("OFFSITE", True, "PostgreSQL porta " + porta + ": este cluster e standby (copia em outro servidor)")
        horas = num(mm.group(1) or 0) * 24 + num(mm.group(2))
        if horas >= 2:
            ALERTAS.append("PostgreSQL porta " + porta + ": standby com atraso de aplicacao de ~" + str(horas) + "h")
    if re.search(r'^\s*\S+\s*\|\s*\S+\s*\|\s*streaming', t.split("### REPLICACAO - STANDBYS")[-1].split("###")[0], re.M):
        ind("OFFSITE", True, "PostgreSQL porta " + porta + ": replica em streaming conectada")
for nome, tit in [("archive_wal_destino.txt", "POSTGRESQL: destino do archive de WAL"),
                  ("ferramentas_backup.txt", "POSTGRESQL: ferramentas de backup"),
                  ("dumps_recentes.txt", "POSTGRESQL: dumps e basebackups em disco")]:
    tx = ler_ev(os.path.join("11_postgresql", nome))
    if not tx.strip():
        continue
    sec(tit)
    corpo = [l for l in tx.splitlines() if l.strip() and not l.startswith("####")]
    for ln in corpo[:24]:
        add("  " + ln.strip()[:110])
    if len(corpo) > 24: add("  ... (truncado, ver pacote completo)")
    if nome == "dumps_recentes.txt":
        if "[SEM EVIDENCIA]" in tx:
            ALERTAS.append("PostgreSQL: nenhum dump/basebackup com menos de 8 dias nos diretorios varridos -> "
                           "NAO COLETADO / A CONFIRMAR (pode estar em outro host ou object storage)")
            ind("LOGICO", False, "PostgreSQL: sem dump recente nos diretorios varridos")
        else:
            if re.search(r'\.(dump|backup|pgdump|sql|sql\.gz|sql\.zst|custom)\b|toc\.dat', tx):
                ind("LOGICO", True, "PostgreSQL: dumps (pg_dump/pg_dumpall) com menos de 8 dias")
                LOCAIS.add("dump logico em disco (PostgreSQL)")
            if re.search(r'backup_manifest|backup_label|base\.tar', tx):
                ind("COPIAS", True, "PostgreSQL: basebackup fisico recente em disco")
                LOCAIS.add("basebackup em disco (PostgreSQL)")
    if nome == "ferramentas_backup.txt":
        if re.search(r'^(pgbackrest|barman|wal-g|pg_probackup):', tx, re.M):
            ind("COPIAS", True, "PostgreSQL: ferramenta de backup fisico instalada (pgBackRest/Barman/WAL-G/pg_probackup)")
        if re.search(r'repo\d*-type\s*=\s*(s3|azure|gcs)', tx, re.I):
            ind("OFFSITE", True, "PostgreSQL: repositorio do pgBackRest em object storage")
            LOCAIS.add("object storage (pgBackRest)")

# ============================ 2c. MYSQL / MARIADB ===========================
myt = ler_ev(os.path.join("12_mysql", "mysql_sql.txt"))
if myt.strip():
    sec("MYSQL/MARIADB")
    if "[ERRO] Sem conexao" in myt:
        add("  Sem conexao a instancia (ver 12_mysql/mysql_sql.txt)")
        ALERTAS.append("MySQL/MariaDB: sem conexao na coleta -> binlog, replicacao e tamanho NAO evidenciados; "
                       "recoletar como root, com WISEDB_SUDO=1 ou WISEDB_MY_USER")
    else:
        def mv(var):
            mm = re.search(r'^\|\s*' + var + r'\s*\|\s*([^|]*?)\s*\|', myt, re.M)
            return mm.group(1) if mm else ""
        mm = re.search(r'^\|\s*(\d+\.\d+\.\d+\S*)\s*\|', myt, re.M)
        if mm: add("  Versao: " + mm.group(1))
        add("  [Binlog] log_bin=" + (mv("log_bin") or "?") + " | binlog_format=" + (mv("binlog_format") or "?") +
            " | expire_logs_days=" + (mv("expire_logs_days") or "-") + " | binlog_expire_logs_seconds=" +
            (mv("binlog_expire_logs_seconds") or "-") + " | sync_binlog=" + (mv("sync_binlog") or "?"))
        for marca, titulo, lim in [("### BANCOS E TAMANHO", "Bancos e tamanho (GB) / MyISAM", 14),
                                   ("### LOGS BINARIOS PRESENTES", "Janela de binlog", 6),
                                   ("### REPLICACAO (esta instancia", "Replicacao", 10),
                                   ("### CRIPTOGRAFIA EM REPOUSO", "Criptografia", 10)]:
            b = bruto(myt, marca, "###", lim)
            if b:
                add("  [" + titulo + "]")
                for ln in b:
                    if not re.match(r'^\s*\+[-+]+\+\s*$', ln): add("  " + ln)
        if mv("log_bin").upper() == "OFF":
            ALERTAS.append("MySQL/MariaDB: log_bin=OFF -> sem binlog, recuperacao so ate o ultimo dump (sem ponto no tempo)")
        bancos = myt.split("### BANCOS E TAMANHO")[-1].split("###")[0]
        myi = [b for b, n in re.findall(r'^\|\s*(\S+)\s*\|\s*[\d.]+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|', bancos, re.M) if num(n) > 0]
        if myi:
            ALERTAS.append("MySQL/MariaDB: tabelas MyISAM em " + ", ".join(myi[:5]) + " -> dump com --single-transaction "
                           "nao e consistente para elas; exige lock ou backup fisico")
        rep_ = myt.split("### REPLICACAO (esta instancia")[-1].split("###")[0]
        if re.search(r'(Slave|Replica)_(IO|SQL)_Running:\s*No', rep_) or re.search(r'Last_(IO_|SQL_)?Error:\s*\S', rep_):
            ALERTAS.append("MySQL/MariaDB: replicacao PARADA ou com erro (ver secao Replicacao)")
        sb = re.search(r'Seconds_Behind_(?:Master|Source):\s*(\d+)', rep_)
        if sb:
            ind("OFFSITE", True, "MySQL/MariaDB: esta instancia e replica (copia em outro servidor)")
            if num(sb.group(1)) > 3600:
                ALERTAS.append("MySQL/MariaDB: replica com atraso de " + sb.group(1) + " segundos")
        if num(mv("wsrep_cluster_size")) > 0 and mv("wsrep_cluster_status") not in ("Primary", ""):
            ALERTAS.append("MySQL/MariaDB: cluster Galera fora do estado Primary (" + mv("wsrep_cluster_status") + ")")
        if "[INFO] Base de ferramenta" in myt:
            ALERTAS.append("MySQL/MariaDB: ha base de ferramenta (zabbix/glpi/grafana) na instancia: confirmar escopo")
for nome, tit in [("ferramentas_backup.txt", "MYSQL/MARIADB: ferramentas e backups fisicos"),
                  ("dumps_recentes.txt", "MYSQL/MARIADB: backups em disco")]:
    tx = ler_ev(os.path.join("12_mysql", nome))
    if not tx.strip():
        continue
    sec(tit)
    corpo = [l for l in tx.splitlines() if l.strip() and not l.startswith("####")]
    for ln in corpo[:22]:
        add("  " + ln.strip()[:110])
    if len(corpo) > 22: add("  ... (truncado, ver pacote completo)")
    if nome == "dumps_recentes.txt":
        if "[SEM EVIDENCIA]" in tx:
            ALERTAS.append("MySQL/MariaDB: nenhum dump/backup fisico com menos de 8 dias nos diretorios varridos -> "
                           "NAO COLETADO / A CONFIRMAR")
            ind("LOGICO", False, "MySQL/MariaDB: sem dump recente nos diretorios varridos")
        elif re.search(r'\.sql(\.gz|\.bz2|\.xz|\.zst)?\b|\.dump', tx):
            ind("LOGICO", True, "MySQL/MariaDB: dumps com menos de 8 dias")
            LOCAIS.add("dump logico em disco (MySQL)")
    if nome == "ferramentas_backup.txt" and re.search(r'^-- .*(xtrabackup_info|mariadb_backup_info)', tx, re.M):
        ind("COPIAS", True, "MySQL/MariaDB: backup fisico (xtrabackup/mariabackup) em disco")
        LOCAIS.add("backup fisico em disco (MySQL)")


SQL_NOVOS = [("ULTIMO BACKUP POR BASE E TIPO", "Ultimo backup por base e tipo (RPO / lacuna de log)", 30),
             ("QUALIDADE DOS BACKUPS", "Qualidade: checksum, danificados, copy_only (15d)", 20),
             ("TIPO DE DESTINO DOS BACKUPS", "Tipo de destino (15d)", 6),
             ("CRIPTOGRAFIA DO BACKUP, TDE", "Criptografia, TDE e certificados", 14),
             ("HISTORICO DE RESTORES", "Historico de RESTORE (365d)", 12),
             ("INTEGRIDADE - ULTIMO CHECKDB", "Ultimo CHECKDB sem erro / paginas suspeitas", 22),
             ("ALTA DISPONIBILIDADE", "Always On / log shipping / mirroring", 10),
             ("RESULTADO DOS JOBS DO AGENT", "Resultado dos jobs do Agent (15d) e historico do msdb", 18)]


def linhas_sql(txt):
    """Linhas de dados de saida sqlcmd -W -s ' | ' (sem cabecalho nem tracos)."""
    out = []
    for ln in txt.splitlines():
        if " | " not in ln and not re.match(r'^\s*\S+\s*$', ln):
            continue
        if re.match(r'^[-| ]+$', ln) or "Msg " in ln:
            continue
        out.append([c.strip() for c in ln.split(" | ")])
    return out[1:] if out else []   # descarta o cabecalho


def alertas_sqlserver(sec_raw, rotulo):
    """sec_raw(marca) -> texto bruto da secao. Gera alertas e indicadores."""
    ult = linhas_sql(sec_raw("ULTIMO BACKUP POR BASE E TIPO"))
    sem_log, sem_full = [], []
    for c in ult:
        if len(c) < 7:
            continue
        base, rec, minlog, horas = c[0], c[1].upper(), c[6], c[5]
        if base in ("model",):
            continue
        if rec in ("FULL", "BULK_LOGGED") and (minlog == "NULL" or num(minlog, 0) > 1440):
            sem_log.append(base)
        if horas == "NULL" or num(horas, 0) > 192:
            sem_full.append(base)
    if sem_log:
        ALERTAS.append("SQL Server " + rotulo + ": base(s) em recovery FULL sem backup de LOG ha mais de 24h: " +
                       ", ".join(sem_log[:6]) + (" ..." if len(sem_log) > 6 else "") +
                       " -> RPO real = ultimo FULL/DIFF e o log cresce sem truncar")
    if sem_full:
        ALERTAS.append("SQL Server " + rotulo + ": base(s) sem FULL/DIFF ha mais de 8 dias (historico do msdb): " +
                       ", ".join(sem_full[:6]) + (" ..." if len(sem_full) > 6 else ""))
    qual = linhas_sql(sec_raw("QUALIDADE DOS BACKUPS"))
    danif = [c[0] for c in qual if len(c) >= 5 and num(c[4]) > 0]
    if danif:
        ALERTAS.append("CRITICO SQL Server " + rotulo + ": backups marcados como DANIFICADOS (is_damaged) em: " + ", ".join(sorted(set(danif))[:6]))
    sem_ck = sorted(set(c[0] for c in qual if len(c) >= 4 and num(c[3]) < num(c[2])))
    if sem_ck:
        ALERTAS.append("SQL Server " + rotulo + ": backups sem CHECKSUM em " + str(len(sem_ck)) + " base(s) (" +
                       ", ".join(sem_ck[:4]) + "): corrupcao no backup so seria percebida no restore")
    dst = sec_raw("TIPO DE DESTINO DOS BACKUPS")
    if "DISCO" in dst:
        LOCAIS.add("disco (SQL Server " + rotulo + ")"); ind("COPIAS", True, "SQL Server " + rotulo + ": backup nativo em disco")
    if "VIRTUAL" in dst:
        ind("COPIAS", True, "SQL Server " + rotulo + ": backup por ferramenta de terceiro (VDI: Veeam/Commvault/agente)")
        LOCAIS.add("ferramenta de terceiro (SQL Server " + rotulo + ")")
    if "URL" in dst:
        ind("OFFSITE", True, "SQL Server " + rotulo + ": backup TO URL (nuvem)"); LOCAIS.add("nuvem via URL (SQL Server)")
    rst = [c for c in linhas_sql(sec_raw("HISTORICO DE RESTORES")) if len(c) >= 3 and re.match(r'\d{4}-\d{2}-\d{2}', c[0])]
    if rst:
        ind("TESTES", True, "SQL Server " + rotulo + ": " + str(len(rst)) + " RESTORE(s) no msdb em 365 dias (confirmar se foram testes)")
    elif sec_raw("HISTORICO DE RESTORES").strip():
        ind("TESTES", False, "SQL Server " + rotulo + ": nenhum RESTORE registrado no msdb em 365 dias")
    chk = linhas_sql(re.split(r'\n[^\n]*file_id', sec_raw("INTEGRIDADE - ULTIMO CHECKDB"))[0])
    datas = [c for c in chk if len(c) >= 2]
    if datas and all(c[1] in ("NULL", "1900-01-01 00:00") for c in datas):
        ALERTAS.append("SQL Server " + rotulo + ": ultimo DBCC CHECKDB sem erro NAO evidenciado (versao sem LastGoodCheckDbTime "
                       "ou nunca executado)")
    elif datas:
        velhas = [c[0] for c in datas if c[1] in ("NULL", "1900-01-01 00:00") or c[1][:10] < LIMITE_CHECKDB]
        if velhas:
            ALERTAS.append("SQL Server " + rotulo + ": base(s) sem CHECKDB sem erro nos ultimos 30 dias: " + ", ".join(velhas[:6]))
    susp = re.split(r'\n[^\n]*file_id[^\n]*', sec_raw("INTEGRIDADE - ULTIMO CHECKDB"))
    if len(susp) > 1 and re.search(r'^\s*\S+\s*\|\s*\d+\s*\|\s*\d+', susp[1], re.M):
        ALERTAS.append("CRITICO SQL Server " + rotulo + ": paginas suspeitas registradas em msdb.dbo.suspect_pages")
    jobs = linhas_sql(sec_raw("RESULTADO DOS JOBS DO AGENT").split("backup_mais_antigo")[0])
    falhos = [c[0] for c in jobs if len(c) >= 3 and num(c[2]) > 0]
    if falhos:
        ALERTAS.append("SQL Server " + rotulo + ": job(s) do Agent com falha em 15 dias: " + ", ".join(falhos[:6]))
    cri = sec_raw("CRIPTOGRAFIA DO BACKUP, TDE")
    tde_ativo = "base_tde" in cri and re.search(r'\|\s*3\s*$', cri.split("base_tde")[-1], re.M)
    cert_sem_bkp = ("certificado" not in cri) or re.search(r'\|\s*NULL\s*\|', cri.split("certificado")[-1].split("base_tde")[0])
    if tde_ativo and cert_sem_bkp:
            ALERTAS.append("SQL Server " + rotulo + ": base(s) com TDE e certificado sem backup da chave privada "
                           "registrado: sem o certificado o backup nao restaura em outro servidor")

LIMITE_CHECKDB = (datetime.datetime.now() - datetime.timedelta(days=30)).strftime("%Y-%m-%d")

# ============================ 3. SQL SERVER =================================
# --- Windows (modulo 04 v1.2): agendamentos e SQL Server por instancia ------
win = achar_ev(os.path.join("04_windows", "windows_evidencias.txt"))
if win:
    tw = ler(win).lstrip("\ufeff")
    sec("SERVIDOR WINDOWS")
    for marca, titulo, lim in [("IDENTIFICACAO DO SERVIDOR", "Identificacao", 8),
                               ("DISCOS E VOLUMES", "Discos", 12),
                               ("MAPEAMENTOS DE REDE", "Mapeamentos (destinos de backup)", 8),
                               ("TAREFAS AGENDADAS RELACIONADAS A BACKUP", "Tarefas agendadas de backup", 30)]:
        b = bruto(tw, marca, "################", lim)
        if b:
            add("  [" + titulo + "]")
            for ln in b: add("  " + ln)
    insts = re.findall(r'#+ SQL \[([^\]]+)\]: VERSAO', tw)
    for inst in insts:
        sec("SQL SERVER (Windows): " + inst)
        for marca, titulo, lim in [("VERSAO SQL SERVER", "Versao", 3),
                                   ("BASES E RECOVERY MODEL", "Bases e recovery model", 25),
                                   ("HISTORICO DE BACKUPS - 15 DIAS", "Historico de backups (15d, amostra)", 30),
                                   ("BASES SEM FULL EM 15 DIAS", "BASES SEM FULL EM 15 DIAS", 12),
                                   ("JOBS DO SQL AGENT / MAINTENANCE PLANS", "Jobs do Agent", 15)]:
            b = bruto(tw, "SQL [" + inst + "]: " + marca, "################", lim)
            if b:
                add("  [" + titulo + "]")
                for ln in b: add("  " + ln)
            if b and any("Could not open a connection" in x or "Login failed" in x for x in b):
                ALERTAS.append("SQL Server " + inst + ": sem conexao no bloco '" + marca + "' -> historico do msdb NAO evidenciado")
            if b and marca.startswith("BASES SEM FULL") and any(re.search(r'\w', x) and "name" not in x and "---" not in x
                                                              and "Could not" not in x for x in b):
                ALERTAS.append("SQL Server " + inst + ": ha bases sem FULL nos ultimos 15 dias (ver secao)")
        for marca, titulo, lim in SQL_NOVOS:
            b = bruto(tw, "SQL [" + inst + "]: " + marca, "################", lim)
            if b:
                add("  [" + titulo + "]")
                for ln in b: add("  " + ln[:110])
        alertas_sqlserver(lambda m, _i=inst: (tw.split("SQL [" + _i + "]: " + m)[-1].split("################")[1]
                                              if ("SQL [" + _i + "]: " + m) in tw else ""), inst)
    if "sqlcmd nao encontrado" in tw:
        ALERTAS.append("Windows: sqlcmd ausente, historico do msdb NAO coletado")

sqlsrv = achar_ev(os.path.join("03_sqlserver", "sqlserver_evidencias.txt"))
if sqlsrv:
    t = ler(sqlsrv)
    sec("SQL SERVER")
    for marca, titulo, lim in [
        ("VERSAO", "Versao", 3),
        ("BASES E RECOVERY MODEL", "Bases e recovery model", 20),
        ("RESUMO: FREQUENCIA POR BASE/TIPO", "Frequencia por base/tipo (15d)", 30),
        ("BASES SEM BACKUP FULL", "BASES SEM FULL EM 15 DIAS", 10),
        ("JOBS DO SQL SERVER AGENT", "Jobs do Agent", 15),
    ]:
        b = bloco(t, "#### " + marca, "####", lim) or bloco(t, marca, "####", lim)
        if b:
            add("  [" + titulo + "]")
            for ln in b: add("  " + ln)
    for marca, titulo, lim in SQL_NOVOS:
        b = bruto(t, "#### " + marca, "################", lim)
        if b:
            add("  [" + titulo + "]")
            for ln in b: add("  " + ln[:110])
    alertas_sqlserver(lambda m, _t=t: (_t.split("#### " + m)[-1].split("################", 2)[1]
                                       if ("#### " + m) in _t else ""), "Linux")
    if re.search(r'BASES SEM (BACKUP )?FULL', t):
        seg = t.split("BASES SEM")[-1][:400]
        if re.search(r'\w', seg.replace("FULL", "").replace("EM 15 DIAS", "").replace("#", "")):
            ALERTAS.append("Ha bases SQL Server sem FULL nos ultimos 15 dias (ver secao)")

# --- Destino real do SBT e agendador do backup fisico ----------------------
# Estes dois blocos existem porque "destino a confirmar" e "agendador inferido"
# eram as duas lacunas mais frequentes na politica do backup fisico.
for dst in sorted(glob_todas_bases(os.path.join("02_oracle", "*_destino_sbt.txt"))):
    t = ler(dst)
    if not t.strip():
        continue
    sid = os.path.basename(dst).replace("_destino_sbt.txt", "")
    sec("DESTINO DO BACKUP FISICO: " + sid)
    m = re.search(r'SBT_LIBRARY:\s*(\S+)', t)
    if m:
        add("  Biblioteca SBT: " + m.group(1))
    m = re.search(r'Tipo de destino \(inferido\):\s*(.+)', t)
    if m:
        add("  Tipo de destino: " + m.group(1).strip())
    m = re.search(r'OPC_CONTAINER\s*=\s*(\S+)', t)
    if m:
        add("  Bucket de destino (OPC_CONTAINER): " + m.group(1))
    else:
        m = re.search(r'OPC_HOST\s*=\s*(\S+)', t)
        if m:
            add("  OPC_HOST: " + m.group(1) + " | OPC_CONTAINER nao presente no pfile")
        elif "Nenhum OPC_PFILE declarado" in t:
            add("  Sem OPC_PFILE: destino provavelmente Recovery Service via wallet SEPS")
        elif "sem permissao de leitura" in t:
            ALERTAS.append(sid + ": OPC_PFILE existe mas nao pudemos ler -> bucket de destino do "
                                 "backup fisico permanece NAO IDENTIFICADO; reexecutar com WISEDB_SUDO=1")
    if "Nenhum SBT_LIBRARY declarado" in t:
        ALERTAS.append(sid + ": nenhum destino SBT declarado no RMAN -> backup fisico apenas em DISK")

dbc = ler_todas_bases(os.path.join("02_oracle", "dbcli_backupconfig.txt"))
if dbc.strip():
    sec("AGENDADOR DO BACKUP FISICO (dbcli)")
    if "[PENDENTE]" in dbc:
        add("  dbcli presente no host, porem sem privilegio para consultar.")
        ALERTAS.append("Agendador do backup fisico nao comprovado: dbcli exige root. "
                       "Reexecutar com WISEDB_SUDO=1, senao o agendador fica como INFERIDO")
    else:
        for ln in dbc.splitlines():
            s = ln.rstrip()
            if re.search(r'(RECOVERY_WINDOW|recoveryWindow|Backup\s*Config|destination|Objectstore|'
                         r'ObjectStore|DISK|NONE|crontab|Schedule|scheduleName|cronExpression)', s, re.I):
                if s.strip() and not s.startswith("####"):
                    add("  " + s.strip()[:110])
        add("  (detalhe completo em 02_oracle/dbcli_backupconfig.txt)")

# --- Nivel de privilegio da coleta -----------------------------------------
priv = ler_todas_bases("nivel_privilegio_coleta.txt") or ler(os.path.join(raiz, "nivel_privilegio_coleta.txt"))
if priv.strip() and "sudo usado .: NAO" in priv:
    ALERTAS.append("Coleta executada sem sudo: /etc/crontab, /etc/cron.d e dbcli nao auditados -> "
                   "pode existir job de backup sob root fora desta evidencia")

# ============================ 4. OCI ========================================
oci_dirs = OCI_DIRS
if OCI_CONTAMINADO:
    sec("OCI - SECAO SUPRIMIDA")
    add("  Ha coletas OCI de mais de um profile neste pacote (" + ", ".join(OCI_PERFIS) + ").")
    add("  Parte da evidencia pertence a outro cliente, portanto nenhum dado de nuvem e")
    add("  exibido aqui. Recolete em pasta limpa antes de gerar a politica.")
elif oci_dirs:
    od = oci_dirs[0]
    sec("OCI - " + os.path.basename(od))

    # Compartments
    t = ler(os.path.join(od, "10_compartments.txt"))
    comps = re.findall(r'\|\s*([A-Za-z0-9_.\- ]{2,40})\s*\|\s*ocid1\.compartment', t)
    if comps:
        add("  Compartments (" + str(len(set(comps))) + "): " + ", ".join(sorted(set(c.strip() for c in comps))[:14]))

    # Instancias
    t = ler(os.path.join(od, "20_compute_instances.txt"))
    inst = re.findall(r'\|\s*([A-Za-z0-9_.\-]{3,40})\s*\|\s*(RUNNING|STOPPED)\s*\|', t)
    if inst:
        add("  Compute instances (" + str(len(inst)) + "):")
        for n, e in inst[:20]: add("    " + n + " [" + e + "]")

    # DB Systems
    t = ler(os.path.join(od, "40_db_systems.txt"))
    dbs = re.findall(r'\|\s*(\w+_EDITION)\s*\|\s*(\w+)\s*\|\s*([A-Za-z0-9_.\-]+)\s*\|', t)
    if dbs:
        add("  DB Systems (" + str(len(dbs)) + "):")
        for ed, st, nm in dbs[:12]: add("    " + nm + " | " + ed + " | " + st)

    # Politicas de volume com schedules resumidos
    t = ler(os.path.join(od, "24_politicas_backup_definidas.txt"))
    pols = re.findall(r'"nome":\s*"([^"]+)",\s*"ocid":[^,]+,\s*"schedules":\s*\[(.*?)\n  \]', t, re.S)
    if pols:
        add("  Politicas de backup de volume:")
        for nome, sch in pols[:12]:
            per = re.findall(r'"period":\s*"(\w+)"', sch)
            ret = re.findall(r'"retention-seconds":\s*(\d+)', sch)
            hor = re.findall(r'"hour-of-day":\s*(\d+)', sch)
            partes = []
            for i, p in enumerate(per):
                d = int(ret[i]) // 86400 if i < len(ret) else "?"
                partes.append(p.replace("ONE_", "").lower() + "=" + str(d) + "d")
            h = ("h" + hor[0]) if hor and hor[0] != "null" else "h?"
            add("    " + nome + ": " + ", ".join(partes) + " (" + h + ")")

    # Boot/block volume backups: agregado por volume
    for arq, rot in [("22_volume_backups_30d.txt", "Boot volume backups"),
                     ("23_block_volume_backups_30d.txt", "Block volume backups")]:
        t = ler(os.path.join(od, arq))
        linhas = re.findall(r'\|\s*(\d{4}-\d{2}-\d{2})T[\d:.]+\+[\d:]+\s*\|\s*(\w+)\s*\|[^|]*\|\s*([^|]+?)\s*\|', t)
        if linhas:
            porvol = {}
            for data, estado, nome in linhas:
                bs = re.sub(r'[_ ]?(backup[_ ]?\d{8}.*|via policy.*|\(Boot Volume\).*)', '', nome).strip()
                bs = bs[:42] or nome[:42]
                d = porvol.setdefault(bs, {"n": 0, "min": data, "max": data, "term": 0})
                d["n"] += 1
                d["min"] = min(d["min"], data); d["max"] = max(d["max"], data)
                if estado == "TERMINATED": d["term"] += 1
            add("  " + rot + " (agregado):")
            for k in sorted(porvol)[:20]:
                d = porvol[k]
                extra = (" | %d TERMINATED" % d["term"]) if d["term"] else ""
                add("    " + k + ": " + str(d["n"]) + " backups | " + d["min"] + " a " + d["max"] + extra)

    # Buckets: versionamento, lifecycle, retention rule (imutabilidade)
    add("  Object Storage (buckets):")
    for det in sorted(glob.glob(os.path.join(od, "31_bucket_*_detalhe.txt"))):
        nome = re.search(r'31_bucket_(.+)_detalhe', os.path.basename(det)).group(1)
        t = ler(det)
        # v1.3 do modulo 05 grava JSON (com KMS e replicacao); v1.2 gravava tabela.
        mjv = re.search(r'"versionamento":\s*"([^"]+)"', t)
        if mjv:
            vers = mjv.group(1)
            mjp = re.search(r'"publico":\s*"([^"]+)"', t); pub = mjp.group(1) if mjp else "?"
            mk = re.search(r'"kms":\s*("([^"]+)"|null)', t)
            kms = "chave do cliente (Vault)" if (mk and mk.group(2)) else "chave gerenciada pela Oracle"
            mo = re.search(r'"objetos":\s*(\d+)', t)
            mb = re.search(r'"bytes":\s*(\d+)', t)
        else:
            m = re.search(r'\|\s*' + re.escape(nome) + r'\s*\|\s*(\S+)\s*\|\s*(\S+)\s*\|\s*(\S+)\s*\|', t)
            vers = m.group(3) if m else "?"
            pub  = m.group(1) if m else "?"
            kms, mo, mb = "", None, None

        rt = ler(os.path.join(od, "31_bucket_" + nome + "_retention.txt"))
        if not rt.strip() or "[AVISO]" in rt or '"items"' not in rt:
            imut = "NAO EVIDENCIADA (consulta falhou ou sem permissao)"
            ALERTAS.append("Bucket " + nome + ": retention rule nao evidenciada (comando falhou) -> imutabilidade A CONFIRMAR")
        elif re.search(r'"items":\s*\[\s*\]', rt):
            imut = "SEM retention rule"
            ALERTAS.append("Bucket " + nome + ": sem retention rule -> nao ha imutabilidade")
            ind("IMUTAVEL", False, "OCI bucket " + nome + ": sem retention rule")
        else:
            am = re.search(r'"time-amount":\s*(\d+)', rt)
            un = re.search(r'"time-unit":\s*"(\w+)"', rt)
            lk = re.search(r'"time-rule-locked":\s*(null|"[^"]*")', rt)
            imut = "retention " + (am.group(1) if am else "?") + " " + (un.group(1).lower() if un else "?")
            if (lk is None) or lk.group(1) == "null":
                imut += " NAO TRAVADA"
                ALERTAS.append("Bucket " + nome + ": retention rule existe mas NAO esta travada (time-rule-locked=null) -> removivel por admin")
                ind("IMUTAVEL", False, "OCI bucket " + nome + ": retention rule NAO travada (parcial)")
            else:
                imut += " TRAVADA"
                ind("IMUTAVEL", True, "OCI bucket " + nome + ": retention rule TRAVADA")

        lf = ler(os.path.join(od, "31_bucket_" + nome + "_lifecycle.txt"))
        if "LifecyclePolicyNotFound" in lf or not lf:
            life = "sem lifecycle"
        else:
            am = re.search(r'"time-amount":\s*(\d+)', lf)
            un = re.search(r'"time-unit":\s*"(\w+)"', lf)
            ac = re.search(r'"action":\s*"(\w+)"', lf)
            life = ((ac.group(1).lower() + " apos " + (am.group(1) if am else "?") + " " + (un.group(1).lower() if un else "?"))
                    if ac else "nao evidenciado (consulta sem regra legivel)")

        add("    " + nome + ": versionamento=" + vers + " | acesso=" + pub + (" | criptografia: " + kms if kms else "") +
            (" | ~" + mo.group(1) + " objetos, " + ("%.1f" % (num(mb.group(1)) / 1024.0**3)) + " GB" if (mo and mb) else ""))
        if (mo and num(mo.group(1)) > 0) or ler(os.path.join(od, "31_bucket_" + nome + "_objetos.txt")).count("|") > 4:
            LOCAIS.add("OCI Object Storage")
        add("      imutabilidade: " + imut + " | lifecycle: " + life)
        if vers.lower() == "disabled":
            ALERTAS.append("Bucket " + nome + ": versionamento desabilitado")

        # Objetos: agregar por prefixo
        ob = ler(os.path.join(od, "31_bucket_" + nome + "_objetos.txt"))
        objs = re.findall(r'\|\s*(\d+)\s*\|\s*(\d{4}-\d{2}-\d{2})T[^|]+\|\s*([^|]+?)\s*\|', ob)
        if objs:
            grupos = {}
            for by, dt, nm in objs:
                pref = re.sub(r'\d{8}.*', '', nm)[:38] or nm[:38]
                g = grupos.setdefault(pref, {"n": 0, "gb": 0.0, "min": dt, "max": dt})
                g["n"] += 1; g["gb"] += int(by) / 1024.0**3
                g["min"] = min(g["min"], dt); g["max"] = max(g["max"], dt)
            for k in sorted(grupos)[:8]:
                g = grupos[k]
                add("      obj: " + k + " -> " + str(g["n"]) + " arq, " +
                    ("%.1f" % g["gb"]) + " GB, " + g["min"] + " a " + g["max"])

    # Backups de DB gerenciado
    t = ler(os.path.join(od, "41_db_backups.txt"))
    fails = len(re.findall(r'\|\s*FAILED\s*\|', t))
    acts = len(re.findall(r'\|\s*ACTIVE\s*\|', t))
    if acts or fails:
        add("  Backups de DB gerenciado pela OCI: " + str(acts) + " ACTIVE, " + str(fails) + " FAILED")
        if fails:
            ALERTAS.append("Ha " + str(fails) + " backup(s) FAILED de database gerenciado pela OCI")

    t = ler(os.path.join(od, "42_autonomous.txt"))
    if re.search(r'\|\s*AVAILABLE\s*\|', t):
        add("  Autonomous Databases: presentes (ver pacote para retencao)")
    t = ler(os.path.join(od, "42b_autonomous_backups.txt"))
    nab = len(re.findall(r'\|\s*ACTIVE\s*\|', t))
    if nab:
        add("  Backups de Autonomous (amostra dos 25 mais recentes): " + str(nab) + " ACTIVE (retencao no pacote)")
        LOCAIS.add("backup gerenciado Autonomous")

    # Capacidades do CLI: grupos ausentes deixam blocos sem evidencia
    cap = ler(os.path.join(od, "00_cli_capacidades.txt"))
    if "grupo recovery: NAO" in cap and "raw-request: NAO" in cap:
        ALERTAS.append("OCI CLI desatualizado (sem grupo recovery e sem raw-request): Recovery Service e replicacao "
                       "de bucket NAO evidenciados -> nao classificar como inexistentes")
    elif "raw-request: SIM" in cap and ("grupo recovery: NAO" in cap or "os replication: NAO" in cap):
        add("  OCI CLI sem alguns grupos: Recovery Service/replicacao consultados via raw-request (JSON da API)")

    # Backup config dos DB Systems: separa "sem backup gerenciado" de "backup
    # feito por RMAN proprio", leitura que antes ficava ambigua.
    t = ler(os.path.join(od, "43_db_backup_config.txt"))
    if t.strip():
        pares = re.findall(r'"nome":\s*"([^"]+)"[\s\S]{0,400}?"auto":\s*(true|false|null)'
                           r'[\s\S]{0,200}?"retencao_dias":\s*(\d+|null)', t)
        if "No such option" in t:
            ALERTAS.append("Backup config dos DB Systems NAO coletado (coleta OCI anterior ao modulo 05 v1.3, comando invalido): "
                           "recoletar para evidenciar auto-backup e retencao")
        if pares:
            add("  Backup automatico gerenciado dos DB Systems:")
            for nome, auto, dias in pares[:12]:
                estado = {"true": "habilitado", "false": "DESABILITADO", "null": "nao informado"}[auto]
                blk = t.split('"nome": "' + nome + '"')[-1][:900]
                ub = re.search(r'"ultimo_backup":\s*"([^"]+)"', blk)
                uf = re.search(r'"ultima_falha":\s*"([^"]+)"', blk)
                tipos = sorted(set(re.findall(r'"tipo":\s*"([^"]+)"', blk)))
                lock = re.search(r'"retention_lock":\s*true', blk)
                add("    " + nome + ": " + estado +
                    (", retencao " + dias + " dias" if dias != "null" else "") +
                    (", destino " + "/".join(tipos) if tipos else "") +
                    (", ultimo backup " + ub.group(1)[:16] if ub else "") +
                    (", retention lock" if lock else ""))
                if auto == "true":
                    LOCAIS.add("backup gerenciado OCI (" + "/".join(tipos or ["DB System"]) + ")")
                    ind("COPIAS", True, "OCI DB System " + nome + ": backup automatico gerenciado")
                if lock:
                    ind("IMUTAVEL", True, "OCI DB System " + nome + ": destino com retention lock")
                if uf and (not ub or uf.group(1) > ub.group(1)):
                    ALERTAS.append("DB System " + nome + ": ultima tentativa de backup gerenciado FALHOU (" + uf.group(1)[:16] +
                                   ") e nao houve sucesso depois")
                if auto == "false":
                    ALERTAS.append("DB System " + nome + ": backup automatico gerenciado da OCI "
                                   "DESABILITADO -> a protecao depende inteiramente do RMAN proprio, "
                                   "confirmar destino e retencao no SHOW ALL")

    # Recovery Service: quando o RMAN esta com RETENTION POLICY TO NONE, a
    # janela real de recuperacao vive aqui e nao no banco.
    t = ler(os.path.join(od, "45_recovery_service.txt"))
    if t.strip():
        if "[CLI DESATUALIZADO]" in t:
            add("  Recovery Service: NAO evidenciado (CLI desatualizado)")
        protegidos = (re.findall(r'"nome":\s*"([^"]+)"[\s\S]{0,300}?"saude":\s*"([^"]+)"', t) or
                      re.findall(r'"displayName":\s*"([^"]+)"[\s\S]{0,900}?"health":\s*"([^"]+)"', t))
        for x in re.findall(r'"redo_habilitado":\s*false|"isRedoLogsEnabled":\s*false', t)[:1]:
            ALERTAS.append("Recovery Service sem real-time redo: RPO do banco = ultimo backup incremental, nao segundos")
        if protegidos:
            LOCAIS.add("OCI Recovery Service"); ind("COPIAS", True, "Recovery Service protegendo " + str(len(protegidos)) + " banco(s)")
            ind("OFFSITE", True, "Recovery Service: copia fora do servidor do banco")
        if re.search(r'"travada_em":\s*"|"policyLockedDateTime":\s*"', t):
            ind("IMUTAVEL", True, "Recovery Service: protection policy com retention lock")
        if protegidos:
            add("  Recovery Service, bancos protegidos:")
            for nome, saude in protegidos[:10]:
                add("    " + nome + ": saude " + saude)
                if saude.upper() not in ("PROTECTED", "HEALTHY"):
                    ALERTAS.append("Recovery Service: banco " + nome + " com saude " + saude +
                                   " -> protecao degradada")
        m = re.findall(r'"dias":\s*(\d+)', t) or re.findall(r'"backupRetentionPeriodInDays":\s*(\d+)', t)
        if m:
            add("  Recovery Service, retencao das politicas (dias): " + ", ".join(sorted(set(m))))
        elif protegidos:
            ALERTAS.append("Recovery Service em uso, porem a retencao da protection policy nao foi "
                           "retornada -> janela de recuperacao do backup fisico permanece A CONFIRMAR")

    # Volume backups com retention lock (imutabilidade de backup de volume)
    vb = ler(os.path.join(od, "22_volume_backups_30d.txt")) + ler(os.path.join(od, "23_block_volume_backups_30d.txt"))
    if "retention_lock" in vb:
        nlk = len(re.findall(r'\|\s*True\s*\|?\s*$', vb, re.M))
        add("  Volume backups com retention lock (amostra dos mais recentes): " + str(nlk))
        if nlk:
            ind("IMUTAVEL", True, "OCI: " + str(nlk) + " volume backup(s) com retention lock")
    if re.search(r'\|\s*(INCREMENTAL|FULL)\s*\|', vb):
        LOCAIS.add("OCI volume backup")

    # Data Guard gerenciado pela OCI
    t = ler(os.path.join(od, "44_data_guard.txt"))
    dgl = [l for l in t.splitlines() if re.search(r'\|\s*(PRIMARY|STANDBY)\s*\|', l)]
    if dgl:
        add("  Data Guard (OCI): " + str(len(dgl)) + " associacao(oes)")
        for l in dgl[:4]: add("    " + re.sub(r'\s+', ' ', l.strip())[:100])
        ind("OFFSITE", True, "OCI: Data Guard associations (standby gerenciado)")

    # MySQL HeatWave e OCI PostgreSQL
    t = ler(os.path.join(od, "46_mysql_heatwave.txt"))
    for nome, hab, dias in re.findall(r'"nome":\s*"([^"]+)"[\s\S]{0,300}?"backup_habilitado":\s*(true|false|null)[\s\S]{0,200}?"retencao_dias":\s*(\d+|null)', t)[:10]:
        blk = t.split('"nome": "' + nome + '"')[-1][:700]
        pitr = re.search(r'"pitr":\s*(true|false|null)', blk)
        cop = re.search(r'"copia_regiao":\s*\[\s*"([^"]+)"', blk)
        add("  MySQL HeatWave " + nome + ": backup " + ("habilitado" if hab == "true" else "DESABILITADO") +
            ", retencao " + dias + " dias, PITR " + (pitr.group(1) if pitr else "?") +
            (", copia para " + cop.group(1) if cop else ", sem copia cross-region"))
        if hab != "true":
            ALERTAS.append("MySQL HeatWave " + nome + ": backup automatico DESABILITADO")
        else:
            LOCAIS.add("OCI MySQL HeatWave backup"); ind("COPIAS", True, "OCI MySQL HeatWave " + nome + ": backup automatico")
        if cop:
            ind("OFFSITE", True, "OCI MySQL HeatWave " + nome + ": copia de backup em " + cop.group(1))
    t = ler(os.path.join(od, "47_oci_postgresql.txt"))
    if re.search(r'\|\s*ACTIVE\s*\|', t):
        add("  OCI Database with PostgreSQL: " + str(len(re.findall(r'\|\s*ACTIVE\s*\|', t))) + " registro(s) ACTIVE (sistemas/backups; ver pacote)")

    # File Storage: snapshots e replicacao
    t = ler(os.path.join(od, "60_fss.txt"))
    fss = re.findall(r'^\|\s*ACTIVE\s*\|\s*\d+\s*\|[^|]*\|\s*([^|]+?)\s*\|\s*ocid1\.filesystem', t, re.M)
    if fss:
        snaps = re.findall(r'^\|\s*(\S+)\s*\|\s*(\S+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*$', t, re.M)
        add("  File Storage (FSS): " + ", ".join(sorted(set(fss))[:6]) + " | blocos de snapshot: " + str(len(snaps)) +
            " | politicas de snapshot: " + str(len(set(re.findall(r'-- schedules da politica (\S+)', t)))))
        if not snaps or all(num(x[3]) == 0 for x in snaps):
            ALERTAS.append("FSS: file system(s) sem snapshot (" + ", ".join(sorted(set(fss))[:4]) +
                           "): conteudo do FSS (ex.: archives do standby manual, dumps) sem copia propria")
        else:
            LOCAIS.add("OCI FSS snapshot")
            ind("COPIAS", True, "OCI FSS: snapshots presentes")

    # Cross-region: unico teste objetivo do criterio offsite do 3-2-1-1-0.
    t = ler(os.path.join(od, "50_cross_region.txt"))
    if t.strip():
        regioes = re.findall(r'\|\s*([a-z]{2}-[a-z]+-\d)\s*\|', t)
        copias = re.findall(r'ocid1\.(?:volumebackup|bootvolumebackup)\.', t)
        if regioes:
            add("  Regioes assinadas pela tenancy: " + ", ".join(sorted(set(regioes))))
        for dst in sorted(glob.glob(os.path.join(od, "51_cross_region_destino_*.txt"))):
            n = len(re.findall(r'ocid1\.(?:volumebackup|bootvolumebackup)\.', ler(dst)))
            rg = os.path.basename(dst).replace("51_cross_region_destino_", "").replace(".txt", "")
            add("  Regiao destino " + rg + ": " + str(n) + " copia(s) de volume recebida(s)")
            copias += ["x"] * n
        if copias:
            add("  Copias de volume em outra regiao: " + str(len(copias)))
            LOCAIS.add("outra regiao OCI"); ind("OFFSITE", True, "OCI: " + str(len(copias)) + " copia(s) de volume em outra regiao")
        else:
            ind("OFFSITE", False, "OCI: nenhuma copia de volume em outra regiao")
            add("  Nenhuma copia cross-region de volume identificada nesta regiao")
            ALERTAS.append("Nenhuma copia cross-region identificada: o criterio '1 copia offsite' do "
                           "3-2-1-1-0 esta atendido apenas no sentido de estar fora do servidor, nao "
                           "fora da regiao. Evento regional afeta producao e backup ao mesmo tempo")

    # Replicacao de bucket: offsite do backup logico.
    reps = sorted(glob.glob(os.path.join(od, "31_bucket_*_replicacao.txt")))
    if reps:
        com_rep = []
        for rp in reps:
            c = ler(rp)
            nome = os.path.basename(rp).replace("31_bucket_", "").replace("_replicacao.txt", "")
            if "[CLI DESATUALIZADO]" in c or "No such command" in c or "Usage:" in c:
                continue
            if '"id"' in c or '"destination-region' in c or '"destinationRegionName"' in c:
                com_rep.append(nome)
        if com_rep:
            add("  Buckets com replicacao ativa: " + ", ".join(com_rep))
            LOCAIS.add("bucket replicado em outra regiao"); ind("OFFSITE", True, "OCI: bucket(s) com replicacao: " + ", ".join(com_rep[:4]))
        else:
            add("  Nenhum bucket com politica de replicacao: dumps existem em uma unica regiao")
elif re.search(r'libopc|oraclecloud|OPC_PFILE|dbcli|libra\.so|ocid1\.', "".join(
        ler(f) for f in glob_todas_bases(os.path.join("02_oracle", "*_destino_sbt.txt"))) + ler_ev("escopo_wizard.txt") + papel):
    ALERTAS.append("Coleta OCI ausente neste pacote: retencao real na nuvem, imutabilidade de bucket, "
                   "politica de boot/block volume e snapshots de FSS nao foram evidenciados")

# ============================ 5. VMs / VEEAM ================================
for arq, tit in [("veeam_agent_linux.txt", "VEEAM AGENT (Linux)"),
                 (os.path.join("07_hypervisor", "hypervisor_evidencias.txt"), "HYPERVISOR")]:
    t = ler_ev(arq)
    if t.strip():
        sec(tit)
        for ln in t.splitlines()[:45]:
            s = ln.rstrip()
            if s.strip() and not s.startswith("#####"):
                add("  " + s[:100])

vt = ler_ev(os.path.join("06_veeam", "veeam_evidencias.txt")).lstrip("\ufeff")
if vt.strip():
    sec("VEEAM B&R")
    def vsec(marca):
        if marca not in vt:
            return ""
        return vt.split(marca)[-1].split("################", 2)[1] if vt.split(marca)[-1].count("################") >= 2 else vt.split(marca)[-1]
    for marca, titulo, lim in [("VERSAO DO VEEAM", "Versao", 3),
                               ("JOBS DE BACKUP", "Jobs de backup", 14),
                               ("BACKUP COPY JOBS", "Backup copy (off-site)", 8),
                               ("REPOSITORIOS", "Repositorios e imutabilidade", 10),
                               ("SCALE-OUT REPOSITORY", "SOBR / capacity tier", 6),
                               ("RESUMO POR JOB (14 DIAS)", "Resumo por job (14d)", 14),
                               ("CRIPTOGRAFIA E HEALTH CHECK", "Criptografia e health check", 12),
                               ("SUREBACKUP - JOBS", "SureBackup (jobs)", 6),
                               ("SUREBACKUP - SESSOES", "SureBackup (sessoes 90d)", 8),
                               ("RESTAURACOES EXECUTADAS", "Restauracoes executadas (90d)", 10),
                               ("BACKUP DA CONFIGURACAO DO VBR", "Backup da configuracao do VBR", 10)]:
        b = bruto(vt, marca, "################", lim)
        if b:
            add("  [" + titulo + "]")
            for ln in b:
                if not re.match(r'^[-\s]+$', ln): add("  " + ln[:110])
    rp = vsec("REPOSITORIOS (")
    if "Sim - " in rp or re.search(r'LinuxHardened|Hardened', rp) or re.search(r'ImutavelCloud\s*:?\s*True|\bTrue\b', vsec("SCALE-OUT REPOSITORY")):
        ind("IMUTAVEL", True, "Veeam: repositorio imutavel/hardened ou capacity tier imutavel")
    elif rp.strip():
        ind("IMUTAVEL", False, "Veeam: nenhum repositorio com imutabilidade")
        ALERTAS.append("Veeam: nenhum repositorio com imutabilidade (hardened/immutability) -> ransomware pode apagar os backups")
    if vsec("JOBS DE BACKUP").strip():
        LOCAIS.add("repositorio Veeam"); ind("COPIAS", True, "Veeam: jobs de backup configurados")
    if re.search(r'\w', vsec("BACKUP COPY JOBS").replace("[AVISO]", "")) and "Name" in vsec("BACKUP COPY JOBS"):
        LOCAIS.add("backup copy Veeam"); ind("OFFSITE", True, "Veeam: backup copy job configurado (confirmar destino)")
    if re.search(r'CapacityTier\w*\s*:?\s*\S', vsec("SCALE-OUT REPOSITORY")):
        ind("OFFSITE", True, "Veeam: SOBR com capacity tier (object storage)")
    falhas = [l for l in vsec("RESUMO POR JOB (14 DIAS)").splitlines() if re.search(r'\s[1-9]\d*\s*$', l)]
    if falhas and "Falha" in vsec("RESUMO POR JOB (14 DIAS)"):
        ALERTAS.append("Veeam: job(s) com falha nos ultimos 14 dias (ver Resumo por job)")
    if "SUREBACKUP: nenhum job" in vt:
        ALERTAS.append("Veeam: sem SureBackup -> nenhuma verificacao automatizada de restauracao")
        ind("TESTES", False, "Veeam: sem SureBackup configurado")
    elif "SUREBACKUP - JOBS" in vt and "[AVISO]" not in vsec("SUREBACKUP - JOBS"):
        ind("TESTES", True, "Veeam: SureBackup configurado")
    if "RESTORE: nenhuma sessao" in vt:
        ind("TESTES", False, "Veeam: nenhuma restauracao nos ultimos 90 dias")
    elif "RESTAURACOES EXECUTADAS" in vt and re.search(r'\d{2}[/-]\d{2}[/-]\d{2,4}', vsec("RESTAURACOES EXECUTADAS")):
        ind("TESTES", True, "Veeam: restauracoes registradas em 90 dias (confirmar se foram testes)")
    cb = vsec("BACKUP DA CONFIGURACAO DO VBR")
    if "CONFIG BACKUP: job de backup da configuracao nao encontrado" in cb or re.search(r'Habilitado\s*:\s*False', cb):
        ALERTAS.append("Veeam: backup da configuracao do VBR ausente ou desabilitado -> perda do servidor VBR exige reconstruir jobs e catalogo")
    elif re.search(r'Criptografado\s*:\s*False', cb):
        ALERTAS.append("Veeam: backup da configuracao SEM criptografia -> credenciais salvas nao sao incluidas no backup")
    if re.search(r'Criptografia\s+HealthCheck', vt) and re.search(r'^\S.*\sFalse\s', vsec("CRIPTOGRAFIA E HEALTH CHECK"), re.M):
        ALERTAS.append("Veeam: ha job(s) sem criptografia ou sem health check (ver secao)")

# ===================== 5b. EVIDENCIAS DE RESTAURACAO ========================
RST_OK = False
ax = ler_ev(os.path.join("09_restore", "anexo_I_evidencias.txt"))
if ax.strip():
    RST_OK = True
    sec("EVIDENCIAS DE RESTAURACAO (Anexo I)")
    linhas = [l.rstrip() for l in ax.splitlines()]
    # Cabecalho do modulo (contagens, agendamentos) completo; registros limitados
    corte = next((i for i, l in enumerate(linhas) if l.startswith("-----")), len(linhas))
    for l in linhas[:corte]:
        if l.strip() and not l.startswith("====="):
            add("  " + l.strip()[:118])
    regs = linhas[corte:]
    n_reg = sum(1 for l in regs if "REGISTRO DE TESTE #" in l)
    for l in regs[:34 * 6]:
        if l.strip() and not l.startswith("-----"):
            add("  " + l.strip()[:118])
    if n_reg > 6:
        add("  (... " + str(n_reg - 6) + " registro(s) adicionais em 09_restore/anexo_I_evidencias.txt)")
    for a in ler_ev(os.path.join("09_restore", "alertas.txt")).splitlines():
        if a.strip():
            ALERTAS.append("Teste de restauracao: " + a.strip())

# ============================ 5c. NUVEM (AWS/GCP/Azure) =====================
def tabela_aws(txt, chave):
    """Linhas de tabela do AWS CLI (--output table) como dicts, a partir do cabecalho que contem 'chave'."""
    linhas = [l for l in txt.splitlines() if l.startswith("|") and l.count("|") >= 3]
    out, cab = [], None
    for l in linhas:
        cel = [c.strip() for c in l.strip().strip("|").split("|")]
        if chave in cel:
            cab = cel; continue
        if cab and len(cel) == len(cab):
            out.append(dict(zip(cab, cel)))
    return out


for cd in sorted(glob.glob(os.path.join(raiz, "coleta_cloud_*"))):
    prov = os.path.basename(cd).split("_")[2] if len(os.path.basename(cd).split("_")) > 2 else "?"
    tudo = dict((os.path.basename(f), ler(f)) for f in glob.glob(os.path.join(cd, "*.txt")))
    if not tudo:
        continue
    sec("NUVEM - " + os.path.basename(cd))
    if prov == "aws":
        vaults = sum((tabela_aws(v, "vault") for k, v in tudo.items() if "_20_" in k), [])
        for v in vaults[:8]:
            add("  vault " + v.get("vault", "?") + ": tipo=" + v.get("tipo", "-") + " pontos=" + v.get("pontos", "?") +
                " lock=" + v.get("lockImutavel", "?") + " (min " + v.get("lockMinDias", "-") + "/max " + v.get("lockMaxDias", "-") + " dias)")
        if vaults:
            LOCAIS.add("AWS Backup vault"); ind("COPIAS", True, "AWS Backup: " + str(len(vaults)) + " vault(s)")
            if any(v.get("lockImutavel") == "True" for v in vaults) or any("AIR_GAPPED" in v.get("tipo", "") for v in vaults):
                ind("IMUTAVEL", True, "AWS: vault com Vault Lock ou logically air-gapped")
            else:
                ind("IMUTAVEL", False, "AWS: nenhum vault com Vault Lock")
                ALERTAS.append("AWS Backup: nenhum vault com Vault Lock (imutabilidade)")
        regras = sum((tabela_aws(v, "retencaoDias") for k, v in tudo.items() if "_22_" in k), [])
        for r in regras[:8]:
            add("  regra " + r.get("regra", "?") + ": agenda " + r.get("agenda", "?") + ", retencao " + r.get("retencaoDias", "?") +
                " dias, copia " + (r.get("copiaDestino") or "-"))
        if any(r.get("copiaDestino") not in (None, "", "None") for r in regras):
            ind("OFFSITE", True, "AWS Backup: regra com copia para outro vault/regiao")
        jobs = " ".join(v for k, v in tudo.items() if "_24_" in k)
        nc, nf = len(re.findall(r'\|\s*COMPLETED\s*\|', jobs)), len(re.findall(r'\|\s*(FAILED|ABORTED|EXPIRED)\s*\|', jobs))
        if nc or nf:
            add("  backup jobs 14d: " + str(nc) + " COMPLETED, " + str(nf) + " FAILED/ABORTED/EXPIRED")
            if nf: ALERTAS.append("AWS Backup: " + str(nf) + " job(s) com falha em 14 dias")
        cop = " ".join(v for k, v in tudo.items() if "_25_" in k)
        if re.search(r'\|\s*COMPLETED\s*\|', cop):
            ind("OFFSITE", True, "AWS: copy jobs concluidos em 14 dias")
        rst = " ".join(v for k, v in tudo.items() if "_28_" in k)
        tst = " ".join(v for k, v in tudo.items() if "_29_" in k)
        nr = len(re.findall(r'\|\s*COMPLETED\s*\|', rst))
        if nr: add("  restore jobs 90d concluidos: " + str(nr)); ind("TESTES", True, "AWS: " + str(nr) + " restore job(s) em 90 dias")
        if "plano" in tst and tabela_aws(tst, "plano"):
            add("  restore testing plans: " + ", ".join(x.get("plano", "?") for x in tabela_aws(tst, "plano")[:4]))
            ind("TESTES", True, "AWS: restore testing plan configurado")
        elif any("_28_" in k for k in tudo) and not nr:
            ind("TESTES", False, "AWS: nenhuma restauracao nem restore testing plan")
        rds = sum((tabela_aws(v, "retencaoDias") for k, v in tudo.items() if "_30_" in k), [])
        for r in rds[:8]:
            add("  RDS " + r.get("db", "?") + ": retencao " + r.get("retencaoDias", "?") + " dias, multiAZ " + r.get("multiAZ", "?"))
            if r.get("retencaoDias") == "0":
                ALERTAS.append("AWS RDS " + r.get("db", "?") + ": backup automatico DESABILITADO (retencao 0)")
        s3 = " ".join(v for k, v in tudo.items() if "_91_" in k)
        if '"ObjectLockEnabled": "Enabled"' in s3:
            ind("IMUTAVEL", True, "AWS S3: bucket com Object Lock")
        if '"ReplicationConfiguration"' in s3:
            ind("OFFSITE", True, "AWS S3: bucket com replicacao")
    elif prov == "azure":
        seg = " ".join(v for k, v in tudo.items() if "_21b_" in k)
        imu = re.findall(r'"imutabilidade":\s*"?([A-Za-z]+)', seg)
        sd = re.findall(r'"softDelete":\s*"?([A-Za-z]+)', seg)
        red = re.findall(r'"storageModelType":\s*"([A-Za-z]+)"|"storageType":\s*"([A-Za-z]+)"', seg)
        crr = re.findall(r'"crossRegionRestoreFlag":\s*(true|false)', seg)
        if seg.strip():
            add("  vaults: imutabilidade=" + (",".join(imu) or "?") + " | soft delete=" + (",".join(sd) or "?") +
                " | redundancia=" + (",".join(a or b for a, b in red) or "?") + " | cross region restore=" + (",".join(crr) or "?"))
            LOCAIS.add("Azure Recovery Services Vault"); ind("COPIAS", True, "Azure: Recovery Services Vault")
            if any(x.lower() in ("locked", "unlocked") for x in imu):
                ind("IMUTAVEL", True, "Azure: vault com imutabilidade " + ",".join(imu))
            else:
                ind("IMUTAVEL", False, "Azure: vault sem imutabilidade"); ALERTAS.append("Azure: Recovery Services Vault sem imutabilidade habilitada")
            if any(x.lower() in ("disabled", "off") for x in sd):
                ALERTAS.append("Azure: soft delete DESABILITADO em vault de backup")
            if any("GeoRedundant" in (a or b) for a, b in red):
                ind("OFFSITE", True, "Azure: vault GRS (copia em regiao par)")
            elif red:
                ind("OFFSITE", False, "Azure: vault sem redundancia geografica (LRS/ZRS)")
        jb = " ".join(v for k, v in tudo.items() if "_23_" in k)
        nf = len(re.findall(r'\bFailed\b', jb))
        if nf: ALERTAS.append("Azure Backup: " + str(nf) + " job(s) Failed em 14 dias")
        if re.search(r'\bRestore\b', jb): ind("TESTES", True, "Azure: job(s) de Restore em 14 dias")
    elif prov == "gcp":
        sq = " ".join(v for k, v in tudo.items() if "cloudsql" in k)
        if re.search(r'enabled:\s*false|"enabled":\s*false', sq):
            ALERTAS.append("GCP Cloud SQL: instancia com backup automatico DESABILITADO")
        if re.search(r'snapshot|backup', " ".join(tudo.values()), re.I):
            LOCAIS.add("GCP snapshot/backup")
    n = 0
    for k in sorted(tudo):
        corpo = [l for l in tudo[k].splitlines() if l.strip() and not l.startswith("##") and not re.match(r'^[-+|=\s]+$', l)]
        if corpo and n < 10:
            add("  [" + k + "] " + (corpo[0].strip()[:90]) + (" (+" + str(len(corpo) - 1) + " linhas)" if len(corpo) > 1 else ""))
            n += 1

# ===================== 5d. MONITORAMENTO E OFF-SITE (modulo 01) =============
mon = ler_ev(os.path.join("01_linux", "monitoramento_backup.txt"))
if mon.strip():
    sec("MONITORAMENTO, NOTIFICACAO, OFF-SITE E CRIPTOGRAFIA (host)")
    corpo = [l for l in mon.splitlines() if l.strip() and not l.startswith("####") and not l.startswith("## ")]
    for ln in corpo[:30]:
        add("  " + ln.strip()[:110])
    if "(nenhum comando de notificacao" in mon and not re.search(r'zabbix_agent|site24x7|backup_report', mon):
        ALERTAS.append("Monitoramento: nenhum envio de notificacao nos scripts de backup e nenhum agente/relatorio "
                       "detectado no host -> falha de backup pode passar despercebida (confirmar Zabbix/relatorio externo)")
    if re.search(r'^\S+:\s+(s3|oracleobjectstorage|azureblob|b2|google cloud storage|swift|sftp|ftp)', mon, re.M | re.I):
        ind("OFFSITE", True, "rclone com remote de nuvem/remoto configurado")
        LOCAIS.add("remote rclone")
scr = " ".join(ler(f) for f in glob_ev(os.path.join("01_linux", "scripts_de_backup", "*.txt")))
off = re.findall(r'(rclone\s+(?:copy|sync|move)|oci\s+os\s+object\s+(?:put|bulk-upload|sync)|aws\s+s3\s+(?:cp|sync)|azcopy\s+(?:copy|sync)|gsutil\s+(?:-m\s+)?(?:cp|rsync)|rsync[^\n|;]*\s[\w.-]+@?[\w.-]+:/|scp\s[^\n]*:/)', scr)
if off:
    ind("OFFSITE", True, "scripts de backup copiam para fora do host: " + ", ".join(sorted(set(re.sub(r'\s+', ' ', o)[:22] for o in off))[:4]))
    LOCAIS.add("copia por script para fora do host")

# ===================== 5e. INDICADORES 3-2-1-1-0 ============================
if RST_OK:
    mv = re.search(r'Ultimo teste valido c/ sucesso:\s*(\d{2}/\d{2}/\d{4})', ax)
    nval = re.search(r'Status \.+: SUCESSO (\d+) \| COM ALERTAS (\d+)', ax)
    if mv:
        ind("TESTES", True, "Modulo 09: ultimo teste de restauracao valido em " + mv.group(1))
    elif nval and num(nval.group(1)) + num(nval.group(2)) == 0:
        ind("TESTES", False, "Modulo 09: nenhum teste de restauracao valido com sucesso no host")
if len(LOCAIS) >= 2:
    ind("COPIAS", True, "locais distintos com copia: " + ", ".join(sorted(LOCAIS)[:6]))
elif len(LOCAIS) == 1:
    ind("COPIAS", False, "apenas um local com copia evidenciado: " + list(LOCAIS)[0])
tipos_midia = set()
for l in LOCAIS:
    ll = l.lower()
    if any(x in ll for x in ("oci", "aws", "azure", "gcp", "sbt", "object", "regiao", "bucket", "url", "nuvem")):
        tipos_midia.add("nuvem/object storage")
    elif any(x in ll for x in ("script", "rclone", "remote", "backup copy")):
        tipos_midia.add("copia remota (script/rclone/backup copy)")
    elif "terceiro" in ll or "veeam" in ll:
        tipos_midia.add("repositorio de ferramenta de backup")
    else:
        tipos_midia.add("disco do servidor")
if len(tipos_midia) >= 2:
    ind("MIDIAS", True, "tipos de midia/armazenamento distintos: " + ", ".join(sorted(tipos_midia)))
NOMES = {"COPIAS": "3 copias (producao + 2)", "MIDIAS": "2 midias/tipos distintos", "OFFSITE": "1 copia fora (off-site)",
         "IMUTAVEL": "1 copia imutavel", "TESTES": "0 erros (restore testado)", "LOGICO": "backup logico (complementar)"}
sec("INDICADORES 3-2-1-1-0 (pre-apuracao automatica: indicio, NAO veredito)")
add("  Regra: so indicio a favor -> ATENDE (confirmar); a favor e contra -> PARCIAL; so contra -> NAO ATENDE;")
add("  sem nenhum indicio -> NAO EVIDENCIADO. A IA valida contra as secoes acima antes de usar na politica.")
SITUACAO = {}
for k in ("COPIAS", "MIDIAS", "OFFSITE", "IMUTAVEL", "TESTES", "LOGICO"):
    a, c = IND[k]["a"], IND[k]["c"]
    sit = ("PARCIAL" if (a and c) else "ATENDE (confirmar)" if a else "NAO ATENDE" if c else "NAO EVIDENCIADO")
    SITUACAO[k] = sit
    add("  " + NOMES[k] + ": " + sit)
    for x in a[:4]: add("      + " + x[:104])
    for x in c[:4]: add("      - " + x[:104])

# ===================== 5f. VULNERABILIDADES E INCONFORMIDADES (v2.6) ========
# Consolida: (1) achados do modulo 13 (Linux/Windows, todos os hosts do pacote),
# (2) alertas deste digest com mapeamento conhecido e (3) criterios 3-2-1-1-0
# nao atendidos. Cada achado tem chave estavel; a mesma chave nao se repete a
# partir de fontes diferentes. Severidade: CRITICO > ALTO > MEDIO > BAIXO > INFO.
SEV_ORD = {"CRITICO": 0, "ALTO": 1, "MEDIO": 2, "BAIXO": 3, "INFO": 4}
SEV_BAIXA = {"CRITICO": "ALTO", "ALTO": "MEDIO", "MEDIO": "BAIXO", "BAIXO": "INFO", "INFO": "INFO"}
OPP = {
 "IMUTAVEL": ("Copia imutavel / air-gapped (protecao contra ransomware)",
              "Repositorio com retencao bloqueada: Veeam Hardened Repository, ExaGrid Retention Time-Lock, "
              "OCI Object Storage com retention rule travada ou AWS S3 Object Lock"),
 "OFFSITE": ("Copia off-site e recuperacao de desastre",
             "OCI Object Storage / Autonomous Recovery Service ou AWS S3 em outra regiao; standby com Data Guard (EE) "
             "ou Dbvisit Standby (SE2); replicacao de servidores com Rackware"),
 "REPOSITORIO": ("Repositorio de backup dedicado, com capacidade e retencao adequadas",
                 "Appliance ExaGrid ou storage dedicado (Dell, HP, IBM), consolidacao com Nutanix, rede de backup isolada"),
 "SEGMENTACAO": ("Segmentacao de rede e hardening dos servidores de banco e backup",
                 "Fortinet (firewall e segmentacao da rede de backup), hardening de SO, acesso nominal e auditoria"),
 "CICLO_VIDA": ("Atualizacao de sistema operacional e banco fora de suporte",
                "Upgrade para Oracle Database 19c e SO suportado; avaliacao de migracao para OCI"),
 "DESEMPENHO": ("Reducao da janela de backup e do tempo de recuperacao (RTO)",
                "Tuning de RMAN (BCT, paralelismo, compressao, dNFS), rede dedicada e appliance de backup"),
 "TESTES": ("Testes de restauracao recorrentes e validacao de backup",
            "Servico recorrente de testes de restore e VALIDATE com evidencia para auditoria (Anexo I)"),
 "GOVERNANCA": ("Governanca de continuidade: BIA, RPO/RTO e Plano de DR",
                "Projeto de continuidade de negocios: BIA, definicao de RPO/RTO com a area de negocio e plano de DR testado"),
 "CRIPTOGRAFIA": ("Protecao dos dados em backup (LGPD)",
                  "Criptografia de backup (RMAN/TDE com licenciamento adequado, OCI ou criptografia no repositorio) e gestao de chaves"),
 "MONITORAMENTO": ("Monitoramento de backup com alerta ativo",
                   "Suporte e monitoramento de missao critica, com alerta de falha e atraso de backup"),
 "CREDENCIAIS": ("Gestao de credenciais das rotinas de backup",
                 "Remocao de senhas em scripts (wallet / Secure External Password Store), cofre de senhas e rotacao"),
 "SUSTENTACAO_DB": ("Consultoria e sustentacao de banco de dados",
                    "Ajustes de RMAN, ARCHIVELOG, retencao, autobackup e backup logico por DBA especialista"),
}
ACHADOS = []
CHAVES = set()
def novo_achado(sev, cat, pilar, chave, tit, evid, imp, rec, opp, host, origem):
    sev = sev.strip().upper()
    if sev not in SEV_ORD: sev = "INFO"
    ACHADOS.append({"severidade": sev, "categoria": cat.strip(), "pilar_32110": pilar.strip() or "-",
                    "chave": chave.strip(), "titulo": tit.strip(), "evidencia": evid.strip(), "impacto": imp.strip(),
                    "recomendacao": rec.strip(), "oportunidade": opp.strip() if opp.strip() in OPP else "SUSTENTACAO_DB",
                    "host": host.strip(), "origem": origem})
    CHAVES.add(chave.strip())
# (1) modulo 13
ARQ13 = sorted(set(glob.glob(os.path.join(raiz, "**", "13_seguranca", "achados.tsv"), recursive=True)))
HOSTS13 = set()
for f13 in ARQ13:
    try:
        lin13 = open(f13, encoding="utf-8-sig", errors="replace").read().splitlines()
    except Exception:
        continue
    for ln in lin13[1:]:
        c = ln.split("\t")
        if len(c) < 11 or not c[1].strip():
            continue
        HOSTS13.add(c[10].strip())
        novo_achado(c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9], c[10], "modulo 13")
CHAVES13 = set(CHAVES)
# (2) alertas com mapeamento conhecido (agrupados por chave)
REGRAS = [
 (r'Credencial embutida em script', "CRED_SCRIPT", "ALTO", "CREDENCIAIS", "-", "CREDENCIAIS",
  "Senha ou token em texto claro em script de backup", "Quem ler o script obtem acesso ao banco ou a nuvem (inclusive a copia off-site)",
  "Mover credenciais para wallet/cofre, restringir permissao do script e rotacionar as credenciais expostas"),
 (r'keystore TDE com FULLY_BACKED_UP=NO', "TDE_CHAVE_SEM_BKP", "CRITICO", "RECUPERABILIDADE", "-", "SUSTENTACAO_DB",
  "Chaves TDE sem backup", "Backup de banco criptografado e irrecuperavel sem a chave", "Fazer backup do keystore TDE e guardar fora do servidor"),
 (r'nenhum backup NIVEL 0 identificado', "ORA_SEM_FULL", "ALTO", "INTEGRIDADE", "3", "SUSTENTACAO_DB",
  "Nenhum backup full/nivel 0 em 35 dias", "Sem ponto de partida valido para restauracao", "Executar full e corrigir o agendamento"),
 (r'sem criptografia RMAN|criptografia de backup desabilitada', "ORA_SEM_CRIPTO", "MEDIO", "CRIPTOGRAFIA", "-", "CRIPTOGRAFIA",
  "Backup de banco sem criptografia", "Dados legiveis por quem acessar o repositorio ou a copia (LGPD)", "Criptografar o backup ou o repositorio"),
 (r'nenhuma execucao de VALIDATE', "ORA_SEM_VALIDATE", "ALTO", "INTEGRIDADE", "0", "TESTES",
  "Backups nao validados (sem VALIDATE/RESTORE VALIDATE)", "Falha no backup so aparece na hora da restauracao", "Agendar VALIDATE periodico e testes de restauracao"),
 (r'RETENTION POLICY TO NONE|RMAN-06525', "ORA_RET_NONE", "ALTO", "RETENCAO", "3", "REPOSITORIO",
  "Sem politica de retencao no RMAN", "Historico depende de exclusao manual", "Definir RECOVERY WINDOW no RMAN"),
 (r'RETENTION POLICY REDUNDANCY 1', "ORA_RET_RED1", "ALTO", "RETENCAO", "3", "REPOSITORIO",
  "Retencao RMAN de uma unica copia (REDUNDANCY 1)", "Perda ou corrupcao desse backup deixa o banco sem recuperacao", "Adotar RECOVERY WINDOW e copias adicionais"),
 (r'^Backup logico: nenhum dump', "LOGICO_AUSENTE", "MEDIO", "RECUPERABILIDADE", "LOGICO", "SUSTENTACAO_DB",
  "Sem backup logico recente", "Restauracao granular exige restaurar o banco inteiro", "Data Pump periodico dos schemas criticos"),
 (r'archive de WAL FALHANDO', "PG_WAL_FALHA", "ALTO", "INTEGRIDADE", "0", "MONITORAMENTO",
  "PostgreSQL com archive de WAL falhando", "Sem PITR a partir da falha", "Corrigir o archive_command e monitorar"),
 (r'sem retention rule|retention rule nao evidenciada', "BUCKET_SEM_RETENCAO", "ALTO", "RANSOMWARE", "1-IMUT", "IMUTAVEL",
  "Bucket de backup sem retention rule (sem imutabilidade)", "Objetos de backup podem ser apagados por credencial comprometida", "Retention rule travada no bucket de backup"),
 (r'backup gerenciado FALHOU', "OCI_DBS_FALHA", "ALTO", "INTEGRIDADE", "0", "MONITORAMENTO",
  "Backup gerenciado de DB System com falha", "Periodo sem backup valido na OCI", "Tratar a causa e monitorar"),
 (r'Nenhuma copia cross-region', "OFFSITE_SEM_REGIAO", "MEDIO", "3-2-1-1-0", "1-OFF", "OFFSITE",
  "Sem copia em outra regiao", "Desastre regional afeta dados e backups", "Copia cross-region automatizada"),
 (r'Veeam: nenhum repositorio com imutabilidade|sem Vault Lock|Vault sem imutabilidade|nenhum vault com Vault Lock', "REPO_SEM_IMUTABILIDADE", "ALTO", "RANSOMWARE", "1-IMUT", "IMUTAVEL",
  "Repositorio de backup sem imutabilidade", "Ransomware ou credencial comprometida apaga os backups", "Repositorio imutavel / retencao bloqueada"),
 (r'Veeam: backup da configuracao SEM criptografia', "VEEAM_CFG_SEM_CRIPTO", "MEDIO", "CRIPTOGRAFIA", "-", "CRIPTOGRAFIA",
  "Backup da configuracao do Veeam sem criptografia", "Recuperacao do servidor Veeam perde as credenciais salvas", "Habilitar criptografia no backup de configuracao"),
 (r'^Monitoramento: nenhum envio de notificacao', "MON_SEM_ALERTA", "MEDIO", "GOVERNANCA", "0", "MONITORAMENTO",
  "Falha de backup sem alerta ativo", "Falhas passam despercebidas ate a necessidade de restauracao", "Alerta de falha/atraso de backup no monitoramento"),
]
agr = {}
for a in ALERTAS:
    for (rx, ch, sev, cat, pil, opp, tit, imp, rec) in REGRAS:
        if re.search(rx, a, re.I):
            if ch in CHAVES13:
                break
            agr.setdefault(ch, [sev, cat, pil, opp, tit, imp, rec, []])[7].append(a)
            break
for ch, (sev, cat, pil, opp, tit, imp, rec, evs) in sorted(agr.items()):
    novo_achado(sev, cat, pil, ch, tit, " | ".join(e[:160] for e in evs[:3]) + (" (+%d)" % (len(evs) - 3) if len(evs) > 3 else ""),
                imp, rec, opp, "", "alertas do digest")
# (3) criterios 3-2-1-1-0 sem achado especifico do mesmo pilar
PIL = {"COPIAS": ("3", "ALTO", "Regra 3-2-1-1-0: menos de 3 copias dos dados (producao + 2 backups)",
                  "Uma unica falha (backup corrompido, apagado ou perdido) elimina a recuperacao", "Manter ao menos 2 copias de backup em locais distintos", "REPOSITORIO"),
       "MIDIAS": ("2", "MEDIO", "Regra 3-2-1-1-0: backups em um unico tipo de midia/tecnologia",
                  "Falha ou ataque a essa tecnologia derruba todas as copias", "Adicionar segunda midia (object storage ou appliance distinto)", "REPOSITORIO"),
       "OFFSITE": ("1-OFF", "ALTO", "Regra 3-2-1-1-0: sem copia off-site (outro site, regiao ou nuvem)",
                   "Incidente no datacenter (incendio, inundacao, ataque) perde dados e backups", "Copia automatizada para outro site, regiao ou nuvem", "OFFSITE"),
       "IMUTAVEL": ("1-IMUT", "CRITICO", "Regra 3-2-1-1-0: sem copia imutavel, offline ou air-gapped",
                    "Ransomware ou credencial comprometida apaga/criptografa todos os backups", "Copia com retencao bloqueada (WORM, Object Lock, time-lock) ou offline", "IMUTAVEL"),
       "TESTES": ("0", "ALTO", "Regra 3-2-1-1-0: sem teste de restauracao com sucesso comprovado",
                  "Falha no backup so e descoberta durante o incidente", "Testes de restauracao periodicos documentados (Anexo I) e VALIDATE", "TESTES"),
       "LOGICO": ("LOGICO", "MEDIO", "Sem backup logico complementar",
                  "Restauracao granular (tabela/schema) exige restaurar o banco inteiro", "Data Pump periodico dos schemas criticos", "SUSTENTACAO_DB")}
pil_cobertos = set(x["pilar_32110"] for x in ACHADOS)
for k in ("IMUTAVEL", "OFFSITE", "COPIAS", "TESTES", "MIDIAS", "LOGICO"):
    sit = SITUACAO.get(k, "NAO EVIDENCIADO")
    pil, sev, tit, imp, rec, opp = PIL[k]
    if pil in pil_cobertos or sit not in ("NAO ATENDE", "NAO EVIDENCIADO"):
        continue
    contra = "; ".join(IND[k]["c"][:3]) or "nenhum indicio a favor nas evidencias coletadas"
    if sit == "NAO EVIDENCIADO":
        sev = SEV_BAIXA[sev]; tit = tit + " (nao evidenciado: confirmar)"
    novo_achado(sev, "3-2-1-1-0", pil, "P_" + k, tit, contra, imp, rec, opp, "", "indicadores 3-2-1-1-0")
# (4) governanca: RPO/RTO nunca vem da coleta
novo_achado("MEDIO", "GOVERNANCA", "-", "GOV_RPO_RTO", "RPO e RTO nao definidos pela area de negocio",
            "Coleta registra RPO/RTO acordados como A DEFINIR; observados em EVIDENCIAS DE RESTAURACAO",
            "Sem meta acordada nao ha como afirmar se o backup atende o negocio nem priorizar investimentos",
            "Definir RPO/RTO por servico com a area de negocio (BIA) e registrar na politica", "GOVERNANCA", "", "regra fixa")
ACHADOS.sort(key=lambda x: (SEV_ORD[x["severidade"]], x["categoria"], x["titulo"]))
for i, x in enumerate(ACHADOS, 1):
    x["id"] = "VUL-%03d" % i
CONT = dict((s, sum(1 for x in ACHADOS if x["severidade"] == s)) for s in SEV_ORD)
sec("VULNERABILIDADES E INCONFORMIDADES (secao 9 da politica; manter os IDs VUL-xxx)")
add("  Total %d | CRITICO %d | ALTO %d | MEDIO %d | BAIXO %d | INFO %d" % (len(ACHADOS), CONT["CRITICO"], CONT["ALTO"], CONT["MEDIO"], CONT["BAIXO"], CONT["INFO"]))
add("  Fontes: modulo 13 (hosts: %s), alertas automaticos, indicadores 3-2-1-1-0, regra fixa de RPO/RTO." % (", ".join(sorted(HOSTS13)) or "nao executado"))
add("  Na politica: tom construtivo (plano de adequacao), sem citar produto/fornecedor; evidencia e acao por item.")
if not ARQ13:
    add("  ! Modulo 13 nao executado neste pacote: matriz PARCIAL (sem varredura de exposicao, exports e hardening).")
for x in ACHADOS:
    lin = "  [%s] %s %s | pilar %s%s | %s" % (x["severidade"], x["id"], x["categoria"], x["pilar_32110"],
                                             (" | " + x["host"]) if x["host"] else "", x["titulo"])
    if x["severidade"] in ("CRITICO", "ALTO"):
        add(lin[:180]); add("      evidencia: " + x["evidencia"][:150]); add("      acao: " + x["recomendacao"][:150])
    elif x["severidade"] == "MEDIO":
        add(lin[:180])
bi = [x for x in ACHADOS if x["severidade"] in ("BAIXO", "INFO")]
if bi:
    add("  BAIXO/INFO (%d): %s" % (len(bi), "; ".join(x["id"] + " " + x["titulo"][:60] for x in bi[:8])))
# Insumo comercial (interno): agrupa achados por oportunidade de adequacao
OPS = []
for cod, (nome, sol) in OPP.items():
    rel = [x for x in ACHADOS if x["oportunidade"] == cod]
    if not rel:
        continue
    pior = min(SEV_ORD[x["severidade"]] for x in rel)
    prio = {0: "P1 imediata", 1: "P2 curto prazo", 2: "P3 medio prazo"}.get(pior, "P4 oportunidade")
    OPS.append({"codigo": cod, "oportunidade": nome, "solucao_referencia": sol, "prioridade": prio,
                "achados": [x["id"] for x in rel], "pior_severidade": [k for k, v in SEV_ORD.items() if v == pior][0]})
OPS.sort(key=lambda o: (o["prioridade"], -len(o["achados"])))
sec("INSUMO COMERCIAL - INTERNO WiseDB (NAO vai para o documento do cliente)")
add("  Oportunidades de adequacao sustentadas pelos achados acima (detalhe em OPORTUNIDADES_COMERCIAIS_INTERNO.txt):")
for o in OPS:
    add("  [%s] %s -> %s" % (o["prioridade"], o["oportunidade"][:70], ", ".join(o["achados"][:8])))
dir_saida = os.path.dirname(os.path.abspath(saida))
try:
    with open(os.path.join(dir_saida, "MATRIZ_VULNERABILIDADES.tsv"), "w", encoding="utf-8") as fm:
        fm.write("ID\tSEVERIDADE\tCATEGORIA\tPILAR_32110\tHOST\tTITULO\tEVIDENCIA\tIMPACTO\tRECOMENDACAO\tOPORTUNIDADE\tCHAVE\tORIGEM\n")
        for x in ACHADOS:
            fm.write("\t".join([x["id"], x["severidade"], x["categoria"], x["pilar_32110"], x["host"], x["titulo"], x["evidencia"],
                                x["impacto"], x["recomendacao"], x["oportunidade"], x["chave"], x["origem"]]) + "\n")
    with open(os.path.join(dir_saida, "OPORTUNIDADES_COMERCIAIS_INTERNO.txt"), "w", encoding="utf-8") as fo:
        fo.write("USO INTERNO WiseDB - NAO ENVIAR AO CLIENTE\n")
        fo.write("Cliente: %s | Gerado em %s | Achados: %d (CRITICO %d, ALTO %d)\n\n" % (
            cliente, datetime.datetime.now().strftime("%d/%m/%Y %H:%M"), len(ACHADOS), CONT["CRITICO"], CONT["ALTO"]))
        for o in OPS:
            fo.write("=" * 78 + "\n[%s] %s\nSolucao de referencia: %s\n\nJustificativa (achados com evidencia):\n" % (
                o["prioridade"], o["oportunidade"], o["solucao_referencia"]))
            for x in ACHADOS:
                if x["id"] in o["achados"]:
                    fo.write("  %s [%s] %s%s\n      Evidencia: %s\n      Impacto: %s\n" % (
                        x["id"], x["severidade"], x["titulo"], (" (" + x["host"] + ")") if x["host"] else "", x["evidencia"][:300], x["impacto"]))
            fo.write("\n")
except Exception as e:
    print("[AVISO] Matriz/oportunidades nao gravadas: " + str(e))

# ============================ 6. ALERTAS ====================================
sec("ALERTAS AUTOMATICOS (para a IA classificar como gap/risco)")
if ALERTAS:
    vistos = []
    for a in ALERTAS:
        if a not in vistos:
            vistos.append(a)
            add("  ! " + a)
else:
    add("  (nenhum alerta automatico gerado)")

sec("PENDENCIAS DE ESCOPO")
add("  - RPO/RTO acordados: A DEFINIR (sem default); valores observados na secao EVIDENCIAS DE RESTAURACAO")
if RST_OK:
    add("  - Teste de restauracao: ver secao EVIDENCIAS DE RESTAURACAO; campos [A PREENCHER] nao inventar")
else:
    add("  - Teste de restauracao: modulo 09 nao executado nesta coleta; anexar Anexo I se existir")
add("  - Definir data de teste apenas apos checar o calendario compartilhado de janelas")
add("")
add("#" * 70)
add("# FIM DO RESUMO - " + cliente + " - dados brutos completos no pacote .tar.gz")
add("#" * 70)

with open(saida, "w", encoding="utf-8") as f:
    f.write("\n".join(L) + "\n")
print("RESUMO gerado: " + saida + " (" + str(len(L)) + " linhas)")

# Versao estruturada para automacao do Painel (aba 3.CONFORMIDADE e alertas).
try:
    alertas_unicos = []
    for a in ALERTAS:
        if a not in alertas_unicos:
            alertas_unicos.append(a)
    estr = {"cliente": cliente, "papel": papel, "gerado_em": datetime.datetime.now().strftime("%Y-%m-%d %H:%M"),
            "indicadores_321110": dict((k, {"situacao": SITUACAO.get(k, "NAO EVIDENCIADO"), "a_favor": IND[k]["a"],
                                            "contra": IND[k]["c"]}) for k in IND),
            "locais_com_copia": sorted(LOCAIS), "alertas": alertas_unicos,
            "vulnerabilidades": {"resumo": CONT, "achados": ACHADOS}, "oportunidades_internas": OPS}
    js = re.sub(r'\.txt$', '', saida) + ".json"
    with open(js, "w", encoding="utf-8") as f:
        json.dump(estr, f, ensure_ascii=False, indent=2)
    print("Estruturado: " + js)
except Exception as e:
    print("[AVISO] JSON estruturado nao gerado: " + str(e))
