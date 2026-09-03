#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
wisedb_digest.py - WiseDB | Gera RESUMO compacto da coleta de backup.

Le a pasta de coleta completa e produz um digest de ~150 linhas, pensado para
ser copiado da tela e colado em uma IA junto com o Modelo da Politica.
Os arquivos brutos completos permanecem no pacote .tar.gz.

Uso: python3 wisedb_digest.py <pasta_coleta> <cliente> <papel_host> [saida]
Compativel com Python 3.6+ (sem f-strings aninhadas).

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
import os, re, sys, glob

raiz    = os.path.abspath(sys.argv[1])
cliente = sys.argv[2] if len(sys.argv) > 2 else "NAO_INFORMADO"
papel   = sys.argv[3] if len(sys.argv) > 3 else "?"
saida   = sys.argv[4] if len(sys.argv) > 4 else os.path.join(raiz, "RESUMO.txt")

L = []      # linhas do resumo
ALERTAS = []

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
            os.path.isdir(os.path.join(d, "04_windows")))


def resolve_base(r):
    if tem_evidencia(r):
        return r
    cand = [d for d in sorted(glob.glob(os.path.join(r, "coleta_*")))
            if os.path.isdir(d) and not os.path.basename(d).startswith("coleta_oci_")]
    for d in cand:
        if tem_evidencia(d):
            return d
    for atual, dirs, _ in os.walk(r):
        if any(x in dirs for x in ("01_linux", "02_oracle", "03_sqlserver", "04_windows")):
            return atual
    return cand[-1] if cand else r


base = resolve_base(raiz)


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
    corpo = resto[:j] if j > 0 else resto
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
    corpo = resto[:j] if j > 0 else resto
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

if papel == "ESTACAO_COLETA_WISEDB":
    add("# NOTA: host de ferramenta WiseDB. Dados locais NAO pertencem ao cliente;")
    add("#       somente a coleta OCI abaixo e evidencia do cliente.")

if not tem_evidencia(base) and not glob_ev("coleta_oci_*"):
    ALERTAS.append("DIGEST: nao localizei 01_linux/02_oracle/03_sqlserver nem coleta_oci_* "
                   "em " + os.path.basename(raiz) + " -> RESUMO incompleto, use o resultado_final.txt")

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
        tem_n0 = re.search(r'^\s*\d{2}/\d{2}[^\n]*?\s0\s+\d', seg_n0, re.M)
        if not tem_n0:
            ALERTAS.append(sid + ": nenhum backup NIVEL 0 identificado em 35 dias -> cadeia incremental "
                           "sem base recente, confirmar politica de full do provedor")

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
    if not corpo:
        ALERTAS.append("Backup logico: arquivo de evidencia vazio, o coletor nao varreu diretorio nenhum "
                       "-> revalidar informando os diretorios de dump como argumento")

# ============================ 3. SQL SERVER =================================
sqlsrv = achar_ev(os.path.join("03_sqlserver", "sqlserver_evidencias.txt")) or \
         achar_ev(os.path.join("04_windows", "windows_evidencias.txt"))
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
    if re.search(r'BASES SEM (BACKUP )?FULL', t):
        seg = t.split("BASES SEM")[-1][:400]
        if re.search(r'\w', seg.replace("FULL", "").replace("EM 15 DIAS", "").replace("#", "")):
            ALERTAS.append("Ha bases SQL Server sem FULL nos ultimos 15 dias (ver secao)")

# ============================ 4. OCI ========================================
oci_dirs = glob_ev("coleta_oci_*")
if oci_dirs:
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
        m = re.search(r'\|\s*' + re.escape(nome) + r'\s*\|\s*(\S+)\s*\|\s*(\S+)\s*\|\s*(\S+)\s*\|', t)
        vers = m.group(3) if m else "?"
        pub  = m.group(1) if m else "?"

        rt = ler(os.path.join(od, "31_bucket_" + nome + "_retention.txt"))
        if '"items": []' in rt:
            imut = "SEM retention rule"
            ALERTAS.append("Bucket " + nome + ": sem retention rule -> nao ha imutabilidade")
        else:
            am = re.search(r'"time-amount":\s*(\d+)', rt)
            un = re.search(r'"time-unit":\s*"(\w+)"', rt)
            lk = re.search(r'"time-rule-locked":\s*(null|"[^"]*")', rt)
            imut = "retention " + (am.group(1) if am else "?") + " " + (un.group(1).lower() if un else "?")
            if (lk is None) or lk.group(1) == "null":
                imut += " NAO TRAVADA"
                ALERTAS.append("Bucket " + nome + ": retention rule existe mas NAO esta travada (time-rule-locked=null) -> removivel por admin")
            else:
                imut += " TRAVADA"

        lf = ler(os.path.join(od, "31_bucket_" + nome + "_lifecycle.txt"))
        if "LifecyclePolicyNotFound" in lf or not lf:
            life = "sem lifecycle"
        else:
            am = re.search(r'"time-amount":\s*(\d+)', lf)
            un = re.search(r'"time-unit":\s*"(\w+)"', lf)
            ac = re.search(r'"action":\s*"(\w+)"', lf)
            life = (ac.group(1).lower() if ac else "?") + " apos " + (am.group(1) if am else "?") + " " + (un.group(1).lower() if un else "?")

        add("    " + nome + ": versionamento=" + vers + " | acesso=" + pub)
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
else:
    ALERTAS.append("Coleta OCI ausente neste pacote: retencao real na nuvem, imutabilidade de bucket, "
                   "politica de boot/block volume e snapshots de FSS nao foram evidenciados")

# ============================ 5. VMs / VEEAM ================================
for arq, tit in [("veeam_agent_linux.txt", "VEEAM AGENT (Linux)"),
                 (os.path.join("06_veeam", "veeam_evidencias.txt"), "VEEAM B&R"),
                 (os.path.join("07_hypervisor", "hypervisor_evidencias.txt"), "HYPERVISOR")]:
    t = ler_ev(arq)
    if t.strip():
        sec(tit)
        for ln in t.splitlines()[:45]:
            s = ln.rstrip()
            if s.strip() and not s.startswith("#####"):
                add("  " + s[:100])

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
add("  - RPO/RTO acordados: verificar no cabecalho do resultado_final.txt")
add("  - Teste de restauracao: nao coletavel automaticamente; anexar Anexo I se existir")
add("  - Definir data de teste apenas apos checar o calendario compartilhado de janelas")
add("")
add("#" * 70)
add("# FIM DO RESUMO - " + cliente + " - dados brutos completos no pacote .tar.gz")
add("#" * 70)

with open(saida, "w", encoding="utf-8") as f:
    f.write("\n".join(L) + "\n")
print("RESUMO gerado: " + saida + " (" + str(len(L)) + " linhas)")
