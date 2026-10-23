#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# CONFIGURACAO DO CLIENTE - EDITE SOMENTE ESTE BLOCO
# ==============================================================================

# Dominio
DOMAIN="sci.net"
WORKGROUP="sci.net"
ADMIN_USER="rbt.google"
USE_RFC2307="yes"
# DC existente
DC1_HOSTNAME="INTBRDC01"
DC1_IP="10.10.200.5"
# Esta VM
DC2_HOSTNAME="INTBRDC02"
DC2_IP="10.10.200.8"
DC2_PREFIX="16"
# Rede
GATEWAY="10.10.1.9"
DNS_FORWARDER="10.l10.200.5"
LAN_CIDR="10.10.0.0/16"
SITE="BR"

# "auto" detecta pela rota default
IFACE="auto"

# ==============================================================================
# NAO EDITAR ABAIXO
# ==============================================================================

REALM="${DOMAIN^^}"
DC1_FQDN="${DC1_HOSTNAME}.${DOMAIN}"
DC2_FQDN="${DC2_HOSTNAME}.${DOMAIN}"
LOG="/var/log/join-ad.log"
SCRIPT_NAME="${0##*/}"

info() { echo; echo "==> $*"; }
ok()   { echo "✔ $*"; }
warn() { echo "AVISO: $*" >&2; }
die()  { echo "ERRO: $*" >&2; exit 1; }

check_root() {
    [[ $EUID -eq 0 ]] || die "Execute com sudo: sudo ./${SCRIPT_NAME}"
}

detect_iface() {
    if [[ "$IFACE" == "auto" ]]; then
        IFACE="$(ip route show default | awk '{print $5; exit}')"
    fi
    [[ -n "$IFACE" ]] || die "Nao foi possivel detectar a interface de rede."
}

ensure_hosts() {
    local tmp
    tmp="$(mktemp)"

    grep -vE "(^|[[:space:]])(${DC2_HOSTNAME}|${DC2_FQDN})([[:space:]]|$)" /etc/hosts > "$tmp" || true
    grep -qE '^127\.0\.0\.1[[:space:]]+localhost' "$tmp" || echo "127.0.0.1 localhost" >> "$tmp"
    echo "${DC2_IP} ${DC2_FQDN} ${DC2_HOSTNAME}" >> "$tmp"

    cat "$tmp" > /etc/hosts
    rm -f "$tmp"
}

network_is_correct() {
    [[ "$(hostname -s)" == "$DC2_HOSTNAME" ]] &&
        ip -4 addr show "$IFACE" | grep -q "inet ${DC2_IP}/"
}

configure_network() {
    info "Validando rede"
    detect_iface

    hostnamectl set-hostname "$DC2_HOSTNAME"
    ensure_hosts

    if network_is_correct; then
        ok "Rede ja correta: ${DC2_IP} em ${IFACE}"
        return
    fi

    info "Configurando rede"

    if [[ -d /etc/cloud/cloud.cfg.d ]]; then
        echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    fi

    local backup_dir
    backup_dir="/root/netplan-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"

    shopt -s nullglob
    for f in /etc/netplan/*.yaml; do
        mv "$f" "$backup_dir/"
    done
    shopt -u nullglob

    cat > /etc/netplan/01-static.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: false
      dhcp6: false
      accept-ra: false
      addresses:
        - ${DC2_IP}/${DC2_PREFIX}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses:
          - ${DC1_IP}
        search:
          - ${DOMAIN}
NETPLAN

    chmod 600 /etc/netplan/01-static.yaml
    netplan generate
    netplan apply
    sleep 3

    if ! network_is_correct; then
        warn "A rede foi alterada. Se o SSH caiu, reconecte em ${DC2_IP}."
        warn "Depois execute novamente: sudo ./${SCRIPT_NAME} install"
        exit 0
    fi

    ok "Rede configurada"
}

configure_prejoin_dns() {
    info "Configurando DNS para o DC1"

    systemctl disable --now systemd-resolved 2>/dev/null || true
    rm -f /etc/resolv.conf

    cat > /etc/resolv.conf <<DNS
search ${DOMAIN}
nameserver ${DC1_IP}
DNS

    ok "DNS -> ${DC1_IP}"
}

ad_is_configured() {
    [[ -f /var/lib/samba/private/sam.ldb ]] || return 1
    command -v testparm >/dev/null 2>&1 || return 1
    [[ "$(testparm -s --parameter-name='server role' 2>/dev/null || true)" == "active directory domain controller" ]]
}

install_packages() {
    info "Instalando Samba/Kerberos/Chrony"

    export DEBIAN_FRONTEND=noninteractive

    debconf-set-selections <<DEBCONF
krb5-config krb5-config/default_realm string ${REALM}
krb5-config krb5-config/kerberos_servers string ${DC1_FQDN}
krb5-config krb5-config/admin_server string ${DC1_FQDN}
krb5-config krb5-config/add_servers_realm string ${REALM}
krb5-config krb5-config/add_servers boolean true
DEBCONF

    apt-get update -q
    apt-get install -y -q \
        samba \
        winbind \
        krb5-user \
        smbclient \
        ldb-tools \
        python3-cryptography \
        chrony \
        dnsutils

    systemctl disable --now smbd nmbd winbind 2>/dev/null || true
    systemctl mask smbd nmbd winbind 2>/dev/null || true

    if [[ -f /etc/samba/smb.conf && ! -f /var/lib/samba/private/sam.ldb ]]; then
        mv /etc/samba/smb.conf "/etc/samba/smb.conf.orig-$(date +%Y%m%d-%H%M%S)"
    fi

    ok "Pacotes instalados"
}

configure_time() {
    info "Validando horario"
    systemctl enable --now chrony >/dev/null 2>&1 || true

    for _ in {1..12}; do
        if chronyc tracking 2>/dev/null | grep -q 'Leap status.*Normal'; then
            ok "Relogio sincronizado"
            return
        fi
        sleep 5
    done

    warn "Chrony ainda nao informou Leap status Normal. Verifique a hora antes de continuar."
    read -r -p "Continuar mesmo assim? [s/N] " resp
    [[ "$resp" =~ ^[sSyY]$ ]] || die "Abortado para ajuste de horario."
}

configure_kerberos() {
    cat > /etc/krb5.conf <<KRB
[libdefaults]
    default_realm = ${REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = true
KRB
    ok "Kerberos pre-join configurado"
}

validate_prejoin() {
    info "Validando ambiente antes do join"

    [[ "$(hostname -f)" == "$DC2_FQDN" ]] || die "hostname -f = $(hostname -f), esperado ${DC2_FQDN}."
    host -t SRV "_kerberos._udp.${DOMAIN}" >/dev/null || die "SRV Kerberos do dominio nao resolve."
    host "$DC1_FQDN" | grep -q "$DC1_IP" || die "${DC1_FQDN} nao resolve para ${DC1_IP}."

    ok "DNS do AD OK"

    info "Autenticando como ${ADMIN_USER}@${REALM}"
    kinit "${ADMIN_USER}@${REALM}" || die "Falha no kinit."
    klist | grep -q "krbtgt/${REALM}@${REALM}" || die "Ticket Kerberos nao encontrado."

    ok "Kerberos OK"
}

join_domain() {
    info "Adicionando ${DC2_HOSTNAME} como DC"

local join_opts=(
    --dns-backend=SAMBA_INTERNAL
    --option="dns forwarder = ${DNS_FORWARDER}"
    --option="ad dc functional level = 2016"
    --site="${SITE}"
    --use-kerberos=required
)

    [[ "$USE_RFC2307" == "yes" ]] && join_opts+=(--option="idmap_ldb:use rfc2307 = yes")

    samba-tool domain join \
        "$DOMAIN" DC \
        -U "${ADMIN_USER}@${REALM}" \
        "${join_opts[@]}"

    ok "Join concluido"
}

configure_postjoin() {
    info "Configurando pos-join"

    cp /var/lib/samba/private/krb5.conf /etc/krb5.conf

    mkdir -p /etc/chrony/conf.d /var/lib/samba/ntp_signd
    cat > /etc/chrony/conf.d/samba-ad.conf <<CHRONY
ntpsigndsocket /var/lib/samba/ntp_signd
allow ${LAN_CIDR}
CHRONY

    chown root:_chrony /var/lib/samba/ntp_signd
    chmod 750 /var/lib/samba/ntp_signd
    systemctl restart chrony

    systemctl unmask samba-ad-dc
    systemctl enable --now samba-ad-dc
    sleep 10

    systemctl is-active --quiet samba-ad-dc || die "samba-ad-dc nao subiu. Veja: journalctl -u samba-ad-dc -n 50"
    ok "samba-ad-dc ativo"

    info "Conferindo registros DNS"

    if ! host "$DC2_FQDN" "$DC1_IP" | grep -q "$DC2_IP"; then
        samba-tool dns add "$DC1_IP" "$DOMAIN" "$DC2_HOSTNAME" A "$DC2_IP" --use-kerberos=required
    fi

    local guid
    guid="$(samba-tool drs showrepl 2>/dev/null | awk '/DSA object GUID/ {print $4; exit}')"
    [[ -n "$guid" ]] || die "Nao foi possivel obter o GUID do DC2."

    if ! host -t CNAME "${guid}._msdcs.${DOMAIN}" "$DC1_IP" >/dev/null 2>&1; then
        samba-tool dns add "$DC1_IP" "_msdcs.${DOMAIN}" "$guid" CNAME "$DC2_FQDN" --use-kerberos=required
    fi

    cat > /etc/resolv.conf <<DNS
search ${DOMAIN}
nameserver ${DC2_IP}
nameserver ${DC1_IP}
DNS

    # Atualiza o netplan para usar o proprio DC e o DC1 como DNS.
    if [[ -f /etc/netplan/01-static.yaml ]]; then
        python3 - <<PY
from pathlib import Path
p = Path('/etc/netplan/01-static.yaml')
s = p.read_text()
s = s.replace('          - ${DC1_IP}\n', '          - ${DC2_IP}\n          - ${DC1_IP}\n', 1)
p.write_text(s)
PY
    fi

    ok "Pos-join concluido"
}

validate_replication() {
    info "Validando replicacao AD"

    systemctl is-active --quiet samba-ad-dc || die "samba-ad-dc nao esta ativo."

    local out
    out="$(samba-tool drs showrepl 2>&1)" || {
        echo "$out"
        die "Falha ao consultar replicacao AD."
    }

    echo "$out"

    if grep -Eq '[1-9][0-9]* consecutive failure\(s\)' <<< "$out"; then
        die "Replicacao AD apresenta falhas."
    fi

    ok "Replicacao AD OK"
}

validate_existing_ad() {
    local realm workgroup

    realm="$(testparm -s --parameter-name=realm 2>/dev/null || true)"
    workgroup="$(testparm -s --parameter-name=workgroup 2>/dev/null || true)"

    [[ "${realm^^}" == "$REALM" ]] || die "Realm atual '${realm}' diferente de '${REALM}'."
    [[ "${workgroup^^}" == "$WORKGROUP" ]] || die "Workgroup atual '${workgroup}' diferente de '${WORKGROUP}'."

    systemctl unmask samba-ad-dc
    systemctl enable --now samba-ad-dc

    ok "AD DC ja configurado. Join nao sera repetido."
    validate_replication
}

show_status() {
    echo
    echo "=== STATUS ==="
    echo "Host:       $(hostname -s)"
    echo "FQDN:       $(hostname -f 2>/dev/null || true)"

    if command -v testparm >/dev/null 2>&1; then
        echo "Samba role: $(testparm -s --parameter-name='server role' 2>/dev/null || true)"
        echo "Realm:      $(testparm -s --parameter-name=realm 2>/dev/null || true)"
        echo "Workgroup:  $(testparm -s --parameter-name=workgroup 2>/dev/null || true)"
    else
        echo "Samba role: nao instalado"
    fi

    echo "Samba DC:   $(systemctl is-active samba-ad-dc 2>/dev/null || true)"

    if command -v samba-tool >/dev/null 2>&1 && [[ -f /var/lib/samba/private/sam.ldb ]]; then
        echo
        samba-tool drs showrepl --summary 2>/dev/null || samba-tool drs showrepl 2>/dev/null || true
    fi
}

do_install() {
    check_root
    exec > >(tee -a "$LOG") 2>&1

    info "Inicio: $(date -Is)"

    detect_iface

    if ad_is_configured; then
        validate_existing_ad
        return
    fi

    configure_network
    configure_prejoin_dns
    install_packages
    configure_time
    configure_kerberos
    validate_prejoin
    join_domain
    configure_postjoin
    validate_replication

    echo
    echo "=== OK ==="
    echo "DC:  ${DC2_FQDN}"
    echo "AD:  ${REALM}"
    echo "Log: ${LOG}"
}

case "${1:-install}" in
    install)
        do_install
        ;;
    status)
        check_root
        show_status
        ;;
    *)
        echo "Uso:"
        echo "  sudo ./${SCRIPT_NAME} install"
        echo "  sudo ./${SCRIPT_NAME} status"
        exit 1
        ;;
esac
