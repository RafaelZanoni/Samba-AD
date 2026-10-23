#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# CONFIGURACAO DO CLIENTE - EDITE SOMENTE ESTE BLOCO
# ==============================================================================

CLIENTE="Internacional"

# Disco local usado como cache do GCSFuse
CACHE_DEVICE="/dev/sdb"

# Cache local do GCSFuse em MiB (~224,6 GiB)
CACHE_SIZE_MB="auto"

# Google Cloud Storage
BUCKET_NAME="sci-service-bkp-storage-recent"

# Compartilhamento Samba
SAMBA_SHARE="gcs"

# Grupo do AD autorizado a acessar o share
AD_ALLOWED_GROUP="Domain Users"

# ==============================================================================
# NAO EDITAR ABAIXO
# ==============================================================================

SCRIPT_NAME="${0##*/}"

CACHE_MOUNT="/cache"
CACHE_DIR="${CACHE_MOUNT}/gcsfuse"
TEMP_DIR="${CACHE_MOUNT}/gcs-tmp"
MOUNT_POINT="/mnt/gcs"

# /cache e descartavel; estas opcoes priorizam desempenho.
CACHE_FSTAB_OPTIONS="defaults,noatime,nodiratime,data=writeback,barrier=0"

GCS_LOCAL_GROUP="gcs-samba"

GCLOUD_CONFIG_DIR="/root/.config/gcloud"
ADC_FILE="${GCLOUD_CONFIG_DIR}/application_default_credentials.json"
GCSFUSE_CONFIG="/etc/gcsfuse/${BUCKET_NAME}.yaml"
LEGACY_GCS_SERVICE="gcsfuse-${BUCKET_NAME}"
LEGACY_GCS_UNIT="/etc/systemd/system/${LEGACY_GCS_SERVICE}.service"
LEGACY_ADC_FILE="/etc/gcsfuse/gcloud/application_default_credentials.json"
GCS_LOG="/var/log/gcsfuse-${BUCKET_NAME}.log"
SETUP_LOG="/var/log/setup-bucket.log"

export CLOUDSDK_CONFIG="$GCLOUD_CONFIG_DIR"

info() { echo; echo "==> $*"; }
ok()   { echo "✔ $*"; }
warn() { echo "AVISO: $*" >&2; }
die()  { echo "ERRO: $*" >&2; exit 1; }

check_root() {
    [[ $EUID -eq 0 ]] || die "Execute com sudo: sudo ./${SCRIPT_NAME}"
}


validate_config() {
    [[ -n "$BUCKET_NAME" ]] || die "Preencha BUCKET_NAME no bloco CONFIGURACAO DO CLIENTE antes de executar."
}

check_samba_ad() {
    command -v testparm >/dev/null 2>&1 || die "Samba nao esta instalado. Rode primeiro o join-ad.sh."
    [[ -f /var/lib/samba/private/sam.ldb ]] || die "Esta maquina nao parece ser um Samba AD DC. Rode primeiro o join-ad.sh."

    local role
    role="$(testparm -s --parameter-name='server role' 2>/dev/null || true)"
    [[ "$role" == "active directory domain controller" ]] || die "Server role atual: '${role}'. Esperado: active directory domain controller."

    systemctl is-active --quiet samba-ad-dc || die "samba-ad-dc nao esta ativo."
}

get_workgroup() {
    WORKGROUP="$(testparm -s --parameter-name=workgroup 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$WORKGROUP" ]] || die "Nao foi possivel descobrir o workgroup do Samba."
    AD_ALLOWED_PRINCIPAL="${WORKGROUP}\\${AD_ALLOWED_GROUP}"
}

get_parent_disk() {
    local dev="$1"
    local parent

    parent="$(lsblk -no PKNAME "$dev" 2>/dev/null | head -n1)"

    if [[ -n "$parent" ]]; then
        echo "/dev/${parent}"
    else
        readlink -f "$dev"
    fi
}

ensure_cache_disk() {
    info "Preparando disco de cache"

    [[ -b "$CACHE_DEVICE" ]] || die "${CACHE_DEVICE} nao existe ou nao e block device. Confira com: lsblk"

    local root_source root_disk cache_disk fs mounted_at children uuid source
    local fstab_tmp current_options

    root_source="$(findmnt -n -o SOURCE /)"
    root_disk="$(get_parent_disk "$root_source")"
    cache_disk="$(get_parent_disk "$CACHE_DEVICE")"

    [[ "$root_disk" != "$cache_disk" ]] || die "${CACHE_DEVICE} pertence ao mesmo disco da raiz (${root_disk})."

    children="$(lsblk -nr -o NAME "$CACHE_DEVICE" | wc -l)"
    fs="$(blkid -s TYPE -o value "$CACHE_DEVICE" 2>/dev/null || true)"

    if [[ -z "$fs" ]]; then
        [[ "$children" -eq 1 ]] || die "${CACHE_DEVICE} possui particoes. Nao vou formatar automaticamente."

        if wipefs -n "$CACHE_DEVICE" 2>/dev/null | grep -qE '0x[0-9a-fA-F]+'; then
            die "${CACHE_DEVICE} possui assinaturas existentes. Nao vou formatar automaticamente."
        fi

        warn "${CACHE_DEVICE} esta vazio. Criando EXT4."
        mkfs.ext4 -F "$CACHE_DEVICE"
        fs="ext4"
        ok "${CACHE_DEVICE} formatado como EXT4"
    fi

    [[ "$fs" == "ext4" ]] || die "${CACHE_DEVICE} possui filesystem '${fs}'. Esperado EXT4."

    mounted_at="$(findmnt -rn -S "$CACHE_DEVICE" -o TARGET 2>/dev/null | head -n1 || true)"
    if [[ -n "$mounted_at" && "$mounted_at" != "$CACHE_MOUNT" ]]; then
        die "${CACHE_DEVICE} ja esta montado em ${mounted_at}."
    fi

    mkdir -p "$CACHE_MOUNT"

    uuid="$(blkid -s UUID -o value "$CACHE_DEVICE")"
    [[ -n "$uuid" ]] || die "Nao foi possivel obter UUID de ${CACHE_DEVICE}."

    if grep -Eq "^[^#]+[[:space:]]+${CACHE_MOUNT}[[:space:]]+" /etc/fstab; then
        grep -Eq "^(UUID=${uuid}|/dev/disk/by-uuid/${uuid})[[:space:]]+${CACHE_MOUNT}[[:space:]]+" /etc/fstab \
            || die "Ja existe uma entrada diferente para ${CACHE_MOUNT} no /etc/fstab."

        fstab_tmp="$(mktemp)"
        awk -v uuid="$uuid" -v mp="$CACHE_MOUNT" -v opts="$CACHE_FSTAB_OPTIONS" '
            /^[[:space:]]*#/ { print; next }
            NF >= 2 && $2 == mp {
                print "UUID=" uuid " " mp " ext4 " opts " 0 2"
                next
            }
            { print }
        ' /etc/fstab > "$fstab_tmp"
        cat "$fstab_tmp" > /etc/fstab
        rm -f "$fstab_tmp"
        ok "${CACHE_MOUNT} atualizado no /etc/fstab"
    else
        echo "UUID=${uuid} ${CACHE_MOUNT} ext4 ${CACHE_FSTAB_OPTIONS} 0 2" >> /etc/fstab
        ok "${CACHE_MOUNT} adicionado ao /etc/fstab"
    fi

    findmnt --verify >/dev/null || die "/etc/fstab invalido apos configurar ${CACHE_MOUNT}."

    if mountpoint -q "$CACHE_MOUNT"; then
        source="$(findmnt -n -o SOURCE "$CACHE_MOUNT")"
        [[ "$(readlink -f "$source")" == "$(readlink -f "$CACHE_DEVICE")" ]] \
            || die "${CACHE_MOUNT} esta montado usando ${source}, nao ${CACHE_DEVICE}."

        current_options="$(findmnt -n -o OPTIONS "$CACHE_MOUNT")"
        if [[ "$current_options" != *"noatime"* || "$current_options" != *"data=writeback"* ]]; then
            warn "${CACHE_MOUNT} ja estava montado. As novas opcoes do fstab entram integralmente apos reboot."
        fi
    else
        mount "$CACHE_MOUNT"
    fi

    mountpoint -q "$CACHE_MOUNT" || die "${CACHE_MOUNT} nao esta montado."
    ok "${CACHE_DEVICE} -> ${CACHE_MOUNT}"
}

ensure_local_group() {
    info "Configurando grupo local do GCSFuse"

    if ! getent group "$GCS_LOCAL_GROUP" >/dev/null; then
        groupadd --system "$GCS_LOCAL_GROUP"
    fi

    GCS_GID="$(getent group "$GCS_LOCAL_GROUP" | cut -d: -f3)"
    [[ "$GCS_GID" =~ ^[0-9]+$ ]] || die "Nao foi possivel obter o GID de ${GCS_LOCAL_GROUP}."

    ok "${GCS_LOCAL_GROUP} -> GID ${GCS_GID}"
}

ensure_fuse_config() {
    touch /etc/fuse.conf
    grep -qxF 'user_allow_other' /etc/fuse.conf || echo 'user_allow_other' >> /etc/fuse.conf
}

install_google_packages() {
    info "Validando GCSFuse/gcloud"

    ensure_fuse_config

    if command -v gcsfuse >/dev/null 2>&1 && command -v gcloud >/dev/null 2>&1; then
        ok "GCSFuse e gcloud ja instalados."
        return
    fi

    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y curl ca-certificates lsb-release fuse3

    install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg -o /usr/share/keyrings/cloud.google.asc

    local codename
    codename="$(lsb_release -c -s)"

    cat > /etc/apt/sources.list.d/gcsfuse.list <<REPO
# Google Cloud Storage FUSE
deb [signed-by=/usr/share/keyrings/cloud.google.asc] https://packages.cloud.google.com/apt gcsfuse-${codename} main
REPO

    cat > /etc/apt/sources.list.d/google-cloud-sdk.list <<REPO
# Google Cloud CLI
deb [signed-by=/usr/share/keyrings/cloud.google.asc] https://packages.cloud.google.com/apt cloud-sdk main
REPO

    apt-get update
    apt-get install -y gcsfuse google-cloud-cli

    command -v gcsfuse >/dev/null 2>&1 || die "gcsfuse nao foi instalado."
    command -v gcloud >/dev/null 2>&1 || die "gcloud nao foi instalado."

    ensure_fuse_config
    ok "GCSFuse e gcloud instalados"
}

prepare_dirs() {
    install -d -m 0700 /etc/gcsfuse "$GCLOUD_CONFIG_DIR"
    mkdir -p "$MOUNT_POINT" "$CACHE_DIR" "$TEMP_DIR"
    chown root:root "$CACHE_DIR" "$TEMP_DIR"
    chmod 0700 "$CACHE_DIR" "$TEMP_DIR"

    # GCSFuse montado pelo fstab roda como root e procura ADC no caminho padrao do root.
    if [[ ! -f "$ADC_FILE" && -f "$LEGACY_ADC_FILE" ]]; then
        cp "$LEGACY_ADC_FILE" "$ADC_FILE"
        chmod 0600 "$ADC_FILE"
        ok "ADC existente migrado para ${ADC_FILE}"
    fi
}

adc_is_valid() {
    [[ -f "$ADC_FILE" ]] || return 1
    gcloud auth application-default print-access-token >/dev/null 2>&1
}

google_login() {
    info "Login Google Cloud"
    echo
    echo "Abra o link mostrado pelo gcloud."
    echo "Autorize com sua conta e cole o codigo aqui."
    echo

    gcloud auth application-default login --no-launch-browser

    [[ -f "$ADC_FILE" ]] || die "ADC nao criado em ${ADC_FILE}."
    chmod 0600 "$ADC_FILE"
    adc_is_valid || die "ADC criado, mas nao foi possivel obter access token."

    ok "ADC valido"
}

ensure_adc() {
    if adc_is_valid; then
        ok "ADC existente e valido."
    else
        google_login
    fi
}

verify_bucket_access() {
    info "Validando acesso ao bucket"

    local token code

    token="$(gcloud auth application-default print-access-token)" || die "Falha ao obter access token."

    code="$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" \
        "https://storage.googleapis.com/storage/v1/b/${BUCKET_NAME}/o?maxResults=1")"

    case "$code" in
        200) ok "Acesso a gs://${BUCKET_NAME} confirmado." ;;
        401) die "Credencial Google recusada." ;;
        403) die "Conta sem permissao em gs://${BUCKET_NAME}." ;;
        404) die "Bucket gs://${BUCKET_NAME} nao existe." ;;
        *)   die "Falha ao validar bucket. HTTP ${code}." ;;
    esac
}

cache_size_mb() {
    if [[ "$CACHE_SIZE_MB" == "auto" ]]; then
        local disk_mb
        disk_mb="$(df -BM --output=size "$CACHE_MOUNT" | tail -1 | tr -dc '0-9')"
        echo $(( disk_mb * 90 / 100 ))
    elif [[ "$CACHE_SIZE_MB" =~ ^[0-9]+$ ]]; then
        echo "$CACHE_SIZE_MB"
    else
        die "CACHE_SIZE_MB deve ser 'auto' ou um numero em MB."
    fi
}

write_gcsfuse_config() {
    info "Gerando configuracao GCSFuse"

    local size_mb
    size_mb="$(cache_size_mb)"

    cat > "$GCSFUSE_CONFIG" <<YAML
cache-dir: ${CACHE_DIR}

file-cache:
  max-size-mb: ${size_mb}
  cache-file-for-range-read: true
  enable-parallel-downloads: true

metadata-cache:
  ttl-secs: 3600
  stat-cache-max-size-mb: 512

write:
  enable-streaming-writes: true

file-system:
  uid: 0
  gid: ${GCS_GID}
  file-mode: "660"
  dir-mode: "770"
  temp-dir: ${TEMP_DIR}

implicit-dirs: true

logging:
  file-path: ${GCS_LOG}
  severity: error
  log-rotate:
    max-file-size-mb: 10
    backup-file-count: 2
    compress: true
YAML

    chmod 0644 "$GCSFUSE_CONFIG"
    ok "GCSFuse: cache=${size_mb} MiB, metadata TTL=3600s, root:${GCS_LOCAL_GROUP} 660/770"
}

configure_gcs_fstab() {
    info "Configurando mount GCSFuse no /etc/fstab"

    # Remove o mecanismo antigo para nao haver dois mounts disputando /mnt/gcs.
    systemctl disable --now "$LEGACY_GCS_SERVICE" >/dev/null 2>&1 || true
    rm -f "$LEGACY_GCS_UNIT"

    local tmp
    tmp="$(mktemp)"

    # Remove somente entradas ativas existentes para /mnt/gcs; comentarios sao preservados.
    awk -v mp="$MOUNT_POINT" '
        /^[[:space:]]*#/ { print; next }
        NF >= 2 && $2 == mp { next }
        { print }
    ' /etc/fstab > "$tmp"

    cat "$tmp" > /etc/fstab
    rm -f "$tmp"

    # O fstab gerencia o mount; o YAML concentra as opcoes avancadas do GCSFuse.
    echo "${BUCKET_NAME} ${MOUNT_POINT} gcsfuse rw,_netdev,allow_other,config_file=${GCSFUSE_CONFIG} 0 0" >> /etc/fstab

    systemctl daemon-reload
    findmnt --verify >/dev/null || die "/etc/fstab invalido apos configurar ${MOUNT_POINT}."

    ok "Mount persistente: gs://${BUCKET_NAME} -> ${MOUNT_POINT} via /etc/fstab"
}

mount_gcs() {
    info "Montando bucket"

    fusermount3 -uz "$MOUNT_POINT" 2>/dev/null || umount -l "$MOUNT_POINT" 2>/dev/null || true
    mount "$MOUNT_POINT" || die "Falha ao montar ${MOUNT_POINT} pelo /etc/fstab."

    local i
    for i in $(seq 1 30); do
        mountpoint -q "$MOUNT_POINT" && break
        sleep 1
    done

    if ! mountpoint -q "$MOUNT_POINT"; then
        [[ -f "$GCS_LOG" ]] && tail -n 30 "$GCS_LOG" >&2
        journalctl -u mnt-gcs.mount -n 30 --no-pager >&2 || true
        die "Bucket nao montou."
    fi

    ok "gs://${BUCKET_NAME} montado em ${MOUNT_POINT}"
}

test_gcs_rw() {
    info "Testando leitura/escrita"

    local test_file
    test_file="${MOUNT_POINT}/.setup-test-$(hostname -s)-$$"

    echo teste > "$test_file" || die "Falha de escrita no bucket."
    [[ "$(cat "$test_file")" == "teste" ]] || die "Falha de leitura no bucket."
    rm -f "$test_file"

    ok "Leitura/escrita GCS OK."
}

remove_existing_share() {
    local tmp
    tmp="$(mktemp)"

    awk -v target="${SAMBA_SHARE,,}" '
        function section_name(line, s) {
            s=line
            sub(/^[[:space:]]*\[/, "", s)
            sub(/\][[:space:]]*$/, "", s)
            return tolower(s)
        }
        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            current=section_name($0)
            skip=(current==target)
        }
        !skip { print }
    ' /etc/samba/smb.conf > "$tmp"

    cat "$tmp" > /etc/samba/smb.conf
    rm -f "$tmp"
}

configure_samba_share() {
    info "Configurando share Samba [${SAMBA_SHARE}]"

    [[ -f /etc/samba/smb.conf ]] || die "/etc/samba/smb.conf nao existe."

    cp /etc/samba/smb.conf "/etc/samba/smb.conf.bak.$(date +%s)"
    remove_existing_share

    cat >> /etc/samba/smb.conf <<SMB

[${SAMBA_SHARE}]
    path = ${MOUNT_POINT}
    read only = No
    browseable = Yes
    guest ok = No
    valid users = @"${AD_ALLOWED_PRINCIPAL}"
    create mask = 0660
    directory mask = 0770
    force group = ${GCS_LOCAL_GROUP}
    vfs objects = dfs_samba4
    ea support = No
    store dos attributes = No
SMB

    testparm -s >/dev/null || die "smb.conf invalido. Backup criado antes da alteracao."
    smbcontrol all reload-config 2>/dev/null || systemctl restart samba-ad-dc

    ok "Share [${SAMBA_SHARE}] restrito a ${AD_ALLOWED_PRINCIPAL}"
}

show_status() {
    get_workgroup 2>/dev/null || true

    echo
    echo "=== STATUS ==="
    echo "Cliente:      ${CLIENTE}"
    echo "Host:         $(hostname -s)"
    echo "Samba role:   $(testparm -s --parameter-name='server role' 2>/dev/null || echo nao-instalado)"
    echo "Samba DC:     $(systemctl is-active samba-ad-dc 2>/dev/null || true)"
    if mountpoint -q "$MOUNT_POINT"; then
        echo "GCSFuse:      mounted"
    else
        echo "GCSFuse:      unmounted"
    fi
    echo "GCS mount:    $(systemctl is-active mnt-gcs.mount 2>/dev/null || true)"

    if mountpoint -q "$CACHE_MOUNT"; then
        echo "Cache:        $(findmnt -n -o SOURCE "$CACHE_MOUNT") -> ${CACHE_MOUNT}"
        echo "Cache opts:   $(findmnt -n -o OPTIONS "$CACHE_MOUNT")"
    else
        echo "Cache:        desmontado"
    fi

    if mountpoint -q "$MOUNT_POINT"; then
        echo "Bucket:       gs://${BUCKET_NAME} -> ${MOUNT_POINT}"
        echo "Permissoes:   $(stat -c '%U:%G %a' "$MOUNT_POINT" 2>/dev/null || true)"
    else
        echo "Bucket:       nao montado"
    fi

    if [[ -f /etc/samba/smb.conf ]] && grep -qi "^[[:space:]]*\[${SAMBA_SHARE}\][[:space:]]*$" /etc/samba/smb.conf; then
        echo "Share:        [${SAMBA_SHARE}] -> ${MOUNT_POINT}"
        echo "Grupo AD:     ${AD_ALLOWED_PRINCIPAL:-nao-resolvido}"
    else
        echo "Share:        ausente"
    fi

    [[ -f "$ADC_FILE" ]] && echo "ADC:          presente" || echo "ADC:          ausente"
    echo
}

do_relogin() {
    check_root
    validate_config
    command -v gcloud >/dev/null 2>&1 || die "gcloud nao instalado."

    prepare_dirs
    rm -f "$ADC_FILE"
    google_login
    verify_bucket_access

    if grep -Eq "^[^#]+[[:space:]]+${MOUNT_POINT}[[:space:]]+" /etc/fstab; then
        mount_gcs
        test_gcs_rw
    fi
}

do_install() {
    check_root
    validate_config
    exec > >(tee -a "$SETUP_LOG") 2>&1

    info "Inicio: $(date -Is)"

    check_samba_ad
    get_workgroup
    cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)"
    ensure_cache_disk
    ensure_local_group
    install_google_packages
    prepare_dirs
    ensure_adc
    verify_bucket_access
    write_gcsfuse_config
    configure_gcs_fstab
    mount_gcs
    test_gcs_rw
    configure_samba_share

    echo
    echo "=== OK ==="
    echo "Cliente: ${CLIENTE}"
    echo "Bucket:  gs://${BUCKET_NAME}"
    echo "Mount:   ${MOUNT_POINT}"
    echo "Cache:   ${CACHE_DEVICE} -> ${CACHE_MOUNT}"
    echo "Share:   \\\\$(hostname -s)\\${SAMBA_SHARE}"
    echo "Grupo:   ${AD_ALLOWED_PRINCIPAL}"
    echo "Mount:   /etc/fstab -> ${MOUNT_POINT}"
    echo "ADC:     ${ADC_FILE}"
    echo "Log:     ${SETUP_LOG}"

    show_status
}

case "${1:-install}" in
    install)
        do_install
        ;;
    status)
        check_root
        validate_config
        show_status
        ;;
    relogin)
        do_relogin
        ;;
    *)
        echo "Uso:"
        echo "  sudo ./${SCRIPT_NAME} install"
        echo "  sudo ./${SCRIPT_NAME} status"
        echo "  sudo ./${SCRIPT_NAME} relogin"
        exit 1
        ;;
esac
