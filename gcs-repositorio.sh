#!/usr/bin/env bash
# =============================================================================
#  gcs-repositorio.sh
#  Repositório de materiais (bucket GCS via gcsfuse) publicado no Samba em UM
#  share, GERENCIADO PELO AD:
#
#    - todas as pastas visíveis e legíveis para todos (USERS_GROUP)
#    - cada pasta gravável só pelo seu grupo do AD
#    - ADMIN_GROUP com controle total (inclusive criar pastas na raiz)
#
#  Gestão pelo AD (Usuários e Computadores do AD / samba-tool):
#    - Criar pasta com escrita para um grupo:
#        crie um grupo de segurança com o prefixo GROUP_PREFIX, ex.: GCS_Fotografia
#        -> pasta "Fotografia", gravável pelos membros do grupo.
#        Para outro nome de pasta (com espaço/acento), preencha o campo
#        "Observações" (Notes / atributo info) do grupo com o nome da pasta.
#    - Dar/tirar escrita de alguém: adicione/remova do grupo.
#        (o usuário precisa fazer logoff/logon para pegar o grupo novo)
#    - Vários grupos numa pasta: coloque-os como membros do grupo GCS_.
#    - Excluir o grupo: a pasta continua (dados preservados) e passa a ser
#      somente leitura (escrita só para ADMIN_GROUP).
#  A sincronização roda a cada SYNC_INTERVAL (timer do systemd).
#
#  Como funciona: gcsfuse não guarda ACLs, então a permissão é aplicada pela
#  montagem. A raiz do bucket é montada com o grupo ADMIN_GROUP (775) e cada
#  pasta é montada por cima, com --only-dir, com o GID do grupo dono (775/664).
#  O Samba acessa com o usuário real do AD e o Linux aplica as permissões.
#
#  Uso (root):
#    gcs-repositorio.sh --dry-run    mostra o que encontraria/geraria no AD
#    gcs-repositorio.sh --install    instala em /usr/local/sbin + timer e sincroniza
#    gcs-repositorio.sh --sync       sincroniza agora (é o que o timer roda)
#    gcs-repositorio.sh --status     mostra pastas, grupos e montagens
#    gcs-repositorio.sh --remove     desfaz tudo (volta ao setup original)
# =============================================================================


set -euo pipefail


# ----------------------------------------------------------------------------
#  VARIÁVEIS
# ----------------------------------------------------------------------------
DOMAIN="FLAMEL"                                   # NetBIOS do domínio (SCI no cliente)
GROUP_PREFIX="GCS_"                               # grupos do AD que definem pastas
ADMIN_GROUP="Domain Admins"                       # controle total do repositório
USERS_GROUP="Domain Users"                        # quem acessa e lê tudo


BUCKET="dt-ariboni-test-bucket"
MOUNT="/mnt/gcs"
SHARE="gcs"                                       # nome do share no Samba


ROOT_SERVICE="gcsfuse-${BUCKET}"                  # serviço criado pelo setup-bucket
BASE_CONFIG="/etc/gcsfuse/${BUCKET}.yaml"         # config do gcsfuse criada pelo setup
CRED_FILE="/etc/gcsfuse/gcloud/application_default_credentials.json"
CLOUDSDK_DIR="/etc/gcsfuse/gcloud"


SMB_CONF="/etc/samba/smb.conf"
SHARES_CONF="/etc/samba/gcs-shares.conf"
SMB_ORIG="/etc/samba/smb.conf.pre-repositorio"   # cópia feita na 1ª instalação


CACHE_BASE="/cache"                               # disco de cache (/dev/sdb)
FOLDER_CACHE_MB=20000                             # cache máximo por pasta (MiB)
RENAME_DIR_LIMIT=200000                           # máx. de arquivos ao renomear/mover uma pasta (0 = proíbe)
DIR_MODE="0775"
FILE_MODE="0664"
SYNC_INTERVAL="5min"


SELF="/usr/local/sbin/gcs-repositorio"
UNIT_DIR="/etc/systemd/system"
UNIT_PREFIX="${ROOT_SERVICE}--"
DROPIN_DIR="${UNIT_DIR}/${ROOT_SERVICE}.service.d"
DROPIN="${DROPIN_DIR}/10-repositorio.conf"
SYNC_UNIT="gcs-repositorio-sync"
LOCK="/run/gcs-repositorio.lock"
MARK="# gerado por gcs-repositorio.sh"
YAML_DIR="/etc/gcsfuse/repositorio"            # configs do gcsfuse geradas (raiz e pastas)


# ----------------------------------------------------------------------------
c_ok="\e[32m"; c_warn="\e[33m"; c_err="\e[31m"; c_info="\e[36m"; c_end="\e[0m"
[[ -t 1 ]] || { c_ok=""; c_warn=""; c_err=""; c_info=""; c_end=""; }   # sem cor no journal
info() { echo -e "${c_info}==> $*${c_end}"; }
ok()   { echo -e "${c_ok}  ✔ $*${c_end}"; }
warn() { echo -e "${c_warn}  ! $*${c_end}" >&2; }
die()  { echo -e "${c_err}  ✘ $*${c_end}" >&2; exit 1; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; echo "${s%"${s##*[![:space:]]}"}"; }


usage() { sed -n '/^#  Uso/,/^# ====/p' "$0" | sed 's/^#//; /====/d'; exit 2; }


MODE="${1:-}"
case "$MODE" in --dry-run|--install|--sync|--status|--remove) ;; *) usage ;; esac


[[ $EUID -eq 0 ]] || die "Rode como root (sudo)."


# ----------------------------------------------------------------------------
#  Funções
# ----------------------------------------------------------------------------
is_dc() { testparm -s --parameter-name="server role" 2>/dev/null | grep -qi "domain controller"; }


# GID numérico de um grupo do AD (vazio se não existir)
gid_of() {
  local line gid
  line="$(wbinfo --group-info="${DOMAIN}\\$1" 2>/dev/null)" || return 1
  gid="$(echo "$line" | awk -F: '{print $(NF-1)}')"
  [[ "$gid" =~ ^[0-9]+$ ]] || return 1
  echo "$gid"
}


# Busca os grupos com o prefixo. Saída: "grupo<TAB>pasta(info)" por linha
ad_groups() {
  local filter="(&(objectClass=group)(sAMAccountName=${GROUP_PREFIX}*))"
  local raw
  if is_dc; then
    raw="$(ldbsearch -H /var/lib/samba/private/sam.ldb "$filter" sAMAccountName info 2>/dev/null)" \
      || die "Falha ao consultar o AD (ldbsearch)."
  else
    raw="$(net ads search -P "$filter" sAMAccountName info 2>/dev/null)" \
      || die "Falha ao consultar o AD (net ads search -P). O servidor está no domínio?"
  fi
  local name="" infov="" infob=0 last="" line
  flush() {
    if [[ -n "$name" ]]; then
      if [[ $infob -eq 1 ]]; then infov="$(echo "$infov" | base64 -d 2>/dev/null || true)"; fi
      infov="${infov%%$'\n'*}"; infov="$(trim "${infov//$'\r'/}")"
      printf '%s\t%s\n' "$name" "$infov"
    fi
    name=""; infov=""; infob=0; last=""
  }
  while IFS= read -r line; do
    case "$line" in
      ""|dn:*|"# record"*) flush ;;
      " "*)   [[ "$last" == "info" ]] && infov+="${line:1}" ;;     # continuação LDIF
      sAMAccountName::*) name="$(echo "${line#sAMAccountName:: }" | base64 -d)"; last="name" ;;
      sAMAccountName:*)  name="${line#sAMAccountName: }"; last="name" ;;
      info::*) infov="${line#info:: }"; infob=1; last="info" ;;
      info:*)  infov="${line#info: }";  infob=0; last="info" ;;
      *) last="" ;;
    esac
  done <<< "$raw"
  flush
}


slug() {
  echo "$1" | LC_ALL=C.UTF-8 iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}


valid_folder() {
  local p="$1"
  [[ -n "$p" && ${#p} -le 100 ]] || return 1
  [[ "$p" != .* ]] || return 1
  [[ "$p" != *[/\\%\$\"\`\'\;]* ]] || return 1
  return 0
}


wait_mount() {
  local mp="$1" i
  for i in $(seq 1 30); do mountpoint -q "$mp" && return 0; sleep 1; done
  return 1
}


# grava stdin em $1 só se mudou; retorna 0 se gravou
write_if_changed() {
  local dest="$1" tmp; tmp="$(mktemp)"; cat > "$tmp"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; return 1; fi
  install -m 0644 "$tmp" "$dest"; rm -f "$tmp"; return 0
}


# Gera um YAML do gcsfuse a partir da config do setup, trocando só o necessário
# (não depende de precedência entre flags e arquivo de configuração).
#   gen_yaml root  <gid>
#   gen_yaml pasta <gid> <pasta> <slug>
gen_yaml() {
  local kind="$1" gid="$2" pasta="${3:-}" s="${4:-}"
  echo "${MARK}"
  RDL="$RENAME_DIR_LIMIT" python3 - "$BASE_CONFIG" "$kind" "$gid" "${DIR_MODE#0}" "${FILE_MODE#0}" "$pasta" \
    "${CACHE_BASE}/gcs--${s}" "${CACHE_BASE}/gcs--${s}-tmp" "$FOLDER_CACHE_MB" "$s" <<'PY'
import os, sys, yaml
base, kind, gid, dm, fm, pasta, cdir, tdir, mb, s = sys.argv[1:11]
with open(base) as f:
    c = yaml.safe_load(f) or {}
fs = c.get("file-system") or {}
c["file-system"] = fs
def mode(old, new):
    return int(new) if isinstance(old, int) else new
fs["uid"] = 0
fs["rename-dir-limit"] = int(os.environ["RDL"])
fs["gid"] = int(gid)
fs["dir-mode"] = mode(fs.get("dir-mode"), dm)
fs["file-mode"] = mode(fs.get("file-mode"), fm)
if kind == "pasta":
    c["only-dir"] = pasta
    c["cache-dir"] = cdir
    fs["temp-dir"] = tdir
    fc = c.get("file-cache") or {}
    c["file-cache"] = fc
    fc["max-size-mb"] = int(mb)
    lg = c.get("logging") or {}
    if lg.get("file-path"):
        p = lg["file-path"]
        lg["file-path"] = (p[:-4] if p.endswith(".log") else p) + "--" + s + ".log"
        c["logging"] = lg
yaml.safe_dump(c, sys.stdout, sort_keys=False, default_flow_style=False, allow_unicode=True)
PY
}


gen_dropin() {
  # repete os ExecStartPre do serviço do setup, precedidos da limpeza de montagem travada
  local pre
  pre="$(grep '^ExecStartPre=' "${UNIT_DIR}/${ROOT_SERVICE}.service" || true)"
  cat <<EOF
${MARK}
# Raiz do bucket: grupo ${DOMAIN}\\${ADMIN_GROUP} (GID ${ADMIN_GID}), ${DIR_MODE}/${FILE_MODE}
[Service]
ExecStartPre=
ExecStartPre=-/usr/bin/umount -l ${MOUNT}
${pre}
ExecStart=
ExecStart=/usr/bin/gcsfuse --foreground -o allow_other --config-file ${YAML_DIR}/raiz.yaml ${BUCKET} ${MOUNT}
ExecStop=
ExecStop=/usr/bin/umount -l ${MOUNT}
EOF
}


gen_unit() {
  local pasta="$1" grupo="$2" gid="$3" s="$4"
  local mp="${MOUNT}/${pasta}" cdir="${CACHE_BASE}/gcs--${s}" tdir="${CACHE_BASE}/gcs--${s}-tmp"
  cat <<EOF
${MARK}
# grupo=${grupo}
# pasta=${pasta}
[Unit]
Description=GCSFuse gs://${BUCKET}/${pasta} -> ${mp} (escrita: ${DOMAIN}\\${grupo})
After=${ROOT_SERVICE}.service
Requires=${ROOT_SERVICE}.service
PartOf=${ROOT_SERVICE}.service
RequiresMountsFor=${CACHE_BASE}


[Service]
Type=simple
Environment=GOOGLE_APPLICATION_CREDENTIALS=${CRED_FILE}
Environment=CLOUDSDK_CONFIG=${CLOUDSDK_DIR}
ExecStartPre=/usr/bin/bash -c 'for i in \$\$(seq 1 30); do mountpoint -q "${MOUNT}" && exit 0; sleep 1; done; exit 1'
ExecStartPre=-/usr/bin/umount -l "${mp}"
ExecStartPre=/usr/bin/mkdir -p "${mp}" "${cdir}" "${tdir}"
ExecStartPre=/usr/bin/find "${cdir}" "${tdir}" -mindepth 1 -delete
ExecStart=/usr/bin/gcsfuse --foreground -o allow_other --config-file ${YAML_DIR}/${s}.yaml ${BUCKET} "${mp}"
ExecStop=/usr/bin/umount -l "${mp}"
Restart=on-failure
RestartSec=15


[Install]
WantedBy=${ROOT_SERVICE}.service
EOF
}


gen_share() {
  # dfs_samba4 só existe em DC; em servidor membro o share não usa módulo VFS
  local vfs="vfs objects ="
  is_dc && vfs="vfs objects = dfs_samba4"
  cat <<EOF
${MARK}
# Repositório: todos leem; cada grupo ${GROUP_PREFIX}* grava na sua pasta
# (permissão aplicada pela montagem); ${ADMIN_GROUP} com controle total.
[${SHARE}]
    path = ${MOUNT}
    browseable = Yes
    read only = No
    valid users = @"${DOMAIN}\\${USERS_GROUP}" @"${DOMAIN}\\${ADMIN_GROUP}"
    admin users = @"${DOMAIN}\\${ADMIN_GROUP}"
    create mask = ${FILE_MODE}
    directory mask = ${DIR_MODE}
    force create mode = ${FILE_MODE}
    force directory mode = ${DIR_MODE}
    nt acl support = No
    ${vfs}
    ea support = No
    store dos attributes = No
    map archive = No
    map readonly = No
    map hidden = No
    map system = No
EOF
}


preflight() {
  for c in gcsfuse wbinfo testparm smbcontrol iconv flock python3; do
    command -v "$c" >/dev/null || die "Comando não encontrado: $c"
  done
  if is_dc; then command -v ldbsearch >/dev/null || die "ldbsearch não encontrado (apt install ldb-tools)."
  else command -v net >/dev/null || die "net não encontrado."; fi
  [[ -f "${UNIT_DIR}/${ROOT_SERVICE}.service" ]] || die "Serviço ${ROOT_SERVICE} não encontrado (rode o setup-bucket antes)."
  [[ -f "$BASE_CONFIG" ]] || die "Config do gcsfuse não encontrada: $BASE_CONFIG"
  [[ -f "$CRED_FILE" ]]   || die "Credencial não encontrada: $CRED_FILE"
  if ! python3 -c 'import yaml' 2>/dev/null; then
    [[ "$MODE" == "--dry-run" ]] && die "Falta o módulo python3-yaml (sudo apt install python3-yaml)."
    info "Instalando python3-yaml"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3-yaml >/dev/null \
      || die "Não consegui instalar python3-yaml."
  fi
  ADMIN_GID="$(gid_of "$ADMIN_GROUP")" || die "Grupo '${DOMAIN}\\${ADMIN_GROUP}' não encontrado."
  gid_of "$USERS_GROUP" >/dev/null     || die "Grupo '${DOMAIN}\\${USERS_GROUP}' não encontrado."
}


# Lê o AD e preenche PASTAS/GRUPOS/GIDS/SLUGS
load_ad() {
  PASTAS=(); GRUPOS=(); GIDS=(); SLUGS=()
  local grupo infov pasta s gid x dup
  while IFS=$'\t' read -r grupo infov; do
    [[ -z "$grupo" ]] && continue
    pasta="${infov:-${grupo#"$GROUP_PREFIX"}}"
    pasta="$(trim "$pasta")"
    if ! valid_folder "$pasta"; then
      warn "Grupo ${grupo}: nome de pasta inválido '${pasta}' (sem / \\ % \$ \" ' \` ;). Ignorado."; continue
    fi
    s="$(slug "$pasta")"
    [[ -n "$s" ]] || { warn "Grupo ${grupo}: nome de pasta '${pasta}' não gera identificador. Ignorado."; continue; }
    dup=0; for x in "${SLUGS[@]}"; do [[ "$x" == "$s" ]] && dup=1; done
    if [[ $dup -eq 1 ]]; then warn "Grupo ${grupo}: pasta '${pasta}' já usada por outro grupo. Ignorado."; continue; fi
    if ! gid=$(gid_of "$grupo"); then warn "Grupo ${grupo}: sem GID (wbinfo). Ignorado."; continue; fi
    PASTAS+=("$pasta"); GRUPOS+=("$grupo"); GIDS+=("$gid"); SLUGS+=("$s")
  done < <(ad_groups | sort -f)
}


ensure_samba() {
  local changed=0
  [[ -f "$SMB_ORIG" ]] || cp "$SMB_CONF" "$SMB_ORIG"
  gen_share | write_if_changed "$SHARES_CONF" && changed=1
  if grep -qi "^[[:space:]]*\[${SHARE}\][[:space:]]*$" "$SMB_CONF"; then
    cp "$SMB_CONF" "${SMB_CONF}.bak.$(date +%s)"
    awk -v s="[${SHARE}]" '/^[[:space:]]*\[/ { t=$0; gsub(/[[:space:]]/,"",t); skip = (tolower(t) == tolower(s)) } !skip' \
      "$SMB_CONF" > "${SMB_CONF}.new" && mv "${SMB_CONF}.new" "$SMB_CONF"
    ok "[${SHARE}] antigo removido do smb.conf"; changed=1
  fi
  if ! grep -q "^[[:space:]]*include[[:space:]]*=[[:space:]]*${SHARES_CONF}[[:space:]]*$" "$SMB_CONF"; then
    printf '\n# Repositório GCS (gcs-repositorio.sh)\ninclude = %s\n' "$SHARES_CONF" >> "$SMB_CONF"; changed=1
  fi
  if [[ $changed -eq 1 ]]; then
    testparm -s >/dev/null 2>&1 || die "testparm falhou após alterar o Samba. Veja: testparm -s"
    smbcontrol all reload-config
    ok "Samba atualizado"
  fi
}


# ============================================================================
#  --status
# ============================================================================
if [[ "$MODE" == "--status" ]]; then
  info "Raiz: ${MOUNT}  $(mountpoint -q "$MOUNT" && stat -c '%U:%G %a' "$MOUNT" || echo 'NÃO MONTADA')"
  found=0
  for f in "${UNIT_DIR}/${UNIT_PREFIX}"*.service; do
    [[ -f "$f" ]] && grep -q "$MARK" "$f" || continue
    found=1
    u="$(basename "$f")"
    g="$(sed -n 's/^# grupo=//p' "$f")"
    mp="${MOUNT}/$(sed -n 's/^# pasta=//p' "$f")"
    st="$(systemctl is-active "$u" 2>/dev/null || true)"
    m="$(mountpoint -q "$mp" && stat -c '%U:%G %a' "$mp" || echo 'não montada')"
    printf '  %-30s %-28s %-8s %s\n' "${mp#"$MOUNT"/}" "${DOMAIN}\\${g}" "$st" "$m"
  done
  [[ $found -eq 1 ]] || echo "  (nenhuma pasta gerenciada)"
  systemctl list-timers "${SYNC_UNIT}.timer" --no-pager 2>/dev/null | head -3 || true
  exit 0
fi


# ============================================================================
#  --remove
# ============================================================================
if [[ "$MODE" == "--remove" ]]; then
  read -r -p "Remover montagens por pasta, timer e voltar a raiz ao setup original? [s/N] " r
  [[ "$r" =~ ^[sSyY]$ ]] || die "Abortado."
  systemctl disable --now "${SYNC_UNIT}.timer" >/dev/null 2>&1 || true
  rm -f "${UNIT_DIR}/${SYNC_UNIT}.timer" "${UNIT_DIR}/${SYNC_UNIT}.service"
  for f in "${UNIT_DIR}/${UNIT_PREFIX}"*.service; do
    [[ -f "$f" ]] && grep -q "$MARK" "$f" || continue
    systemctl disable --now "$(basename "$f")" >/dev/null 2>&1 || true
    rm -f "$f"; ok "removida: $(basename "$f")"
  done
  rm -f "$DROPIN"; rmdir "$DROPIN_DIR" 2>/dev/null || true
  rm -rf "$YAML_DIR"
  systemctl daemon-reload
  systemctl restart "${ROOT_SERVICE}.service"
  ok "raiz voltou à configuração do setup"
  if [[ -f "$SMB_ORIG" ]]; then
    read -r -p "Restaurar o smb.conf de antes do repositório (${SMB_ORIG})? [s/N] " r
    if [[ "$r" =~ ^[sSyY]$ ]]; then
      cp "$SMB_CONF" "${SMB_CONF}.bak.$(date +%s)"; cp "$SMB_ORIG" "$SMB_CONF"
      rm -f "$SHARES_CONF"; smbcontrol all reload-config; ok "smb.conf restaurado"
    fi
  fi
  exit 0
fi


# ============================================================================
#  --dry-run / --sync / --install
# ============================================================================
exec 9>"$LOCK"
flock -n 9 || { warn "Outra sincronização em andamento."; exit 0; }


preflight
info "Lendo grupos ${GROUP_PREFIX}* no AD ($(is_dc && echo 'DC local' || echo 'membro do domínio'))"
load_ad
for i in "${!PASTAS[@]}"; do
  ok "${PASTAS[$i]}  <-  ${DOMAIN}\\${GRUPOS[$i]} (GID ${GIDS[$i]})"
done
[[ ${#PASTAS[@]} -gt 0 ]] || warn "Nenhum grupo ${GROUP_PREFIX}* encontrado: só a raiz será publicada."


if [[ "$MODE" == "--dry-run" ]]; then
  echo; info "Raiz (${DROPIN})"; gen_dropin
  echo; info "Raiz (${YAML_DIR}/raiz.yaml)"; gen_yaml root "$ADMIN_GID"
  for i in "${!PASTAS[@]}"; do
    echo; info "${UNIT_PREFIX}${SLUGS[$i]}.service"
    gen_unit "${PASTAS[$i]}" "${GRUPOS[$i]}" "${GIDS[$i]}" "${SLUGS[$i]}"
    echo; info "${YAML_DIR}/${SLUGS[$i]}.yaml"
    gen_yaml pasta "${GIDS[$i]}" "${PASTAS[$i]}" "${SLUGS[$i]}"
  done
  echo; info "Samba (${SHARES_CONF})"; gen_share
  exit 0
fi


if [[ "$MODE" == "--install" ]]; then
  info "Instalando"
  [[ "$(readlink -f "$0")" == "$SELF" ]] || install -m 0755 "$0" "$SELF"
  ok "script: $SELF"
  cat > "${UNIT_DIR}/${SYNC_UNIT}.service" <<EOF
${MARK}
[Unit]
Description=Sincroniza pastas do repositório GCS com os grupos ${GROUP_PREFIX}* do AD
After=samba-ad-dc.service winbind.service ${ROOT_SERVICE}.service


[Service]
Type=oneshot
ExecStart=${SELF} --sync
EOF
  cat > "${UNIT_DIR}/${SYNC_UNIT}.timer" <<EOF
${MARK}
[Unit]
Description=Sincronização periódica do repositório GCS com o AD


[Timer]
OnBootSec=2min
OnUnitActiveSec=${SYNC_INTERVAL}


[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable "${SYNC_UNIT}.timer" >/dev/null 2>&1
  ok "timer: a cada ${SYNC_INTERVAL}"
  warn "A raiz e as pastas serão remontadas agora: quem estiver no share pode ter erro por alguns segundos."
  read -r -p "Continuar? [s/N] " r; [[ "$r" =~ ^[sSyY]$ ]] || die "Abortado (timer instalado, mas não iniciado)."
fi


# ----------------------------------------------------------------------------
#  Sincronização (idempotente)
# ----------------------------------------------------------------------------
info "Sincronizando"
ROOT_CHANGED=0; RELOAD=0; CHANGED=(); WANT=()


mkdir -p "$DROPIN_DIR" "$YAML_DIR"
if gen_yaml root "$ADMIN_GID" | write_if_changed "${YAML_DIR}/raiz.yaml"; then ROOT_CHANGED=1; fi
if gen_dropin | write_if_changed "$DROPIN"; then ROOT_CHANGED=1; RELOAD=1; fi
if [[ $ROOT_CHANGED -eq 1 ]]; then ok "raiz: configuração atualizada"; fi


for i in "${!PASTAS[@]}"; do
  u="${UNIT_PREFIX}${SLUGS[$i]}.service"; WANT+=("$u")
  ch=0
  if gen_yaml pasta "${GIDS[$i]}" "${PASTAS[$i]}" "${SLUGS[$i]}" | write_if_changed "${YAML_DIR}/${SLUGS[$i]}.yaml"; then ch=1; fi
  if gen_unit "${PASTAS[$i]}" "${GRUPOS[$i]}" "${GIDS[$i]}" "${SLUGS[$i]}" | write_if_changed "${UNIT_DIR}/${u}"; then ch=1; RELOAD=1; fi
  if [[ $ch -eq 1 ]]; then CHANGED+=("$u"); ok "pasta nova/alterada: ${PASTAS[$i]}"; fi
done


for f in "${UNIT_DIR}/${UNIT_PREFIX}"*.service; do
  [[ -f "$f" ]] && grep -q "$MARK" "$f" || continue
  n="$(basename "$f")"; keep=0
  for w in "${WANT[@]}"; do [[ "$w" == "$n" ]] && keep=1; done
  if [[ $keep -eq 0 ]]; then
    systemctl disable --now "$n" >/dev/null 2>&1 || true
    sl="${n#"$UNIT_PREFIX"}"; rm -f "$f" "${YAML_DIR}/${sl%.service}.yaml"; RELOAD=1
    warn "grupo removido do AD: ${n} desmontada (pasta e dados mantidos, agora só leitura)"
  fi
done


[[ $RELOAD -eq 1 ]] && systemctl daemon-reload


if [[ $ROOT_CHANGED -eq 1 ]]; then
  for w in "${WANT[@]}"; do systemctl stop "$w" >/dev/null 2>&1 || true; done
  systemctl restart "${ROOT_SERVICE}.service"
  wait_mount "$MOUNT" || die "Raiz não montou. Veja: journalctl -u ${ROOT_SERVICE} -n 50"
  sleep 2
  [[ "$(stat -c %g "$MOUNT")" == "$ADMIN_GID" ]] \
    || die "Raiz montou com GID $(stat -c %g "$MOUNT"), esperado ${ADMIN_GID}. Veja: systemctl cat ${ROOT_SERVICE}; journalctl -u ${ROOT_SERVICE} -n 50"
  ok "raiz: $(stat -c '%U:%G %a' "$MOUNT")"
  CHANGED=("${WANT[@]}")
fi


FAIL=0
for i in "${!PASTAS[@]}"; do
  u="${WANT[$i]}"; mp="${MOUNT}/${PASTAS[$i]}"
  systemctl enable "$u" >/dev/null 2>&1 || true
  need=0
  for c in "${CHANGED[@]}"; do [[ "$c" == "$u" ]] && need=1; done
  if [[ $need -eq 1 ]]; then systemctl restart "$u"
  elif ! systemctl is-active --quiet "$u"; then systemctl start "$u"
  else continue; fi
  if wait_mount "$mp"; then ok "${PASTAS[$i]}: $(stat -c '%U:%G %a' "$mp")"
  else warn "Pasta '${PASTAS[$i]}' não montou. Veja: journalctl -u ${u} -n 50"; FAIL=1; fi
done


ensure_samba


if [[ "$MODE" == "--install" ]]; then
  systemctl start "${SYNC_UNIT}.timer"
  echo
  info "Instalado. Gestão a partir de agora pelo AD:"
  cat <<EOF
  - Nova pasta:   crie o grupo ${GROUP_PREFIX}<Nome> (Observações = nome da pasta, opcional)
  - Escrita:      membros do grupo ${GROUP_PREFIX}<Nome>
  - Leitura:      ${DOMAIN}\\${USERS_GROUP} (todas as pastas)
  - Total:        ${DOMAIN}\\${ADMIN_GROUP}
  - Sincroniza a cada ${SYNC_INTERVAL}; para forçar: sudo ${SELF} --sync
  - Situação:     sudo ${SELF} --status
EOF
fi


exit $FAIL