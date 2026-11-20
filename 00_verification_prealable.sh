#!/usr/bin/env bash
# =============================================================================
#  00 - Vérification préliminaire
# -----------------------------------------------------------------------------
#  Contrôle que la machine est prête à recevoir Prometheus et Alertmanager.
#  Ce script ne modifie rien sur le système.
#
#  Usage : sudo ./00_verification_prealable.sh [-h]
#  Code retour : 0 = prêt (avertissements éventuels), 1 = au moins une erreur
# =============================================================================
set -uo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
    sed -n '3,10p' "${BASH_SOURCE[0]}" | sed 's/^#  \{0,1\}//'
    exit 0
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

ERRORS=0
WARNINGS=0
check_ok()   { log_ok "$*"; }
check_warn() { log_warn "$*"; WARNINGS=$((WARNINGS + 1)); }
check_fail() { log_error "$*"; ERRORS=$((ERRORS + 1)); }

# Seul le lancement direct écrit un journal (pas l'appel depuis 01)
[[ "${BUNDLE_SKIP_LOG:-no}" == "yes" ]] || init_log "00_verification_prealable"

log_title "00 - Vérification préliminaire"
log_info "Prometheus ${PROMETHEUS_VERSION} / Alertmanager ${ALERTMANAGER_VERSION}"

# --- 1. Droits ---------------------------------------------------------------
log_title "Droits d'exécution"
if [[ ${EUID} -eq 0 ]]; then
    check_ok "Exécution en tant que root"
else
    check_fail "Le script doit être exécuté en tant que root (sudo)"
fi

# --- 2. Système --------------------------------------------------------------
log_title "Système"
OS_INFO="$(detect_os)"
log_info "Système détecté : ${OS_INFO} - noyau $(uname -r)"
if [[ "$(uname -s)" != "Linux" ]]; then
    check_fail "Système non Linux : $(uname -s)"
else
    check_ok "Système Linux"
fi

ARCH="$(detect_arch)"
if [[ "${ARCH}" == "unsupported" ]]; then
    check_fail "Architecture non supportée : $(uname -m)"
else
    check_ok "Architecture : $(uname -m) (paquets linux-${ARCH})"
fi

if cmd_exists systemctl && [[ -d /run/systemd/system ]]; then
    check_ok "systemd est le gestionnaire de services actif"
else
    check_fail "systemd n'est pas actif : les services ne pourront pas être installés"
fi

# --- 3. Commandes requises ---------------------------------------------------
log_title "Commandes requises"
for cmd in tar gzip install useradd groupadd getent id sha256sum awk sed grep; do
    if cmd_exists "${cmd}"; then
        check_ok "Commande disponible : ${cmd}"
    else
        check_fail "Commande manquante : ${cmd}"
    fi
done

if cmd_exists curl || cmd_exists wget; then
    check_ok "Client HTTP disponible : $(cmd_exists curl && echo curl || echo wget)"
else
    check_warn "Ni curl ni wget : téléchargement et tests de santé HTTP impossibles"
fi

if cmd_exists ss || cmd_exists netstat; then
    check_ok "Outil de contrôle des ports disponible : $(cmd_exists ss && echo ss || echo netstat)"
else
    check_warn "Ni ss ni netstat : contrôle des ports approximatif"
fi

# --- 4. Ressources -----------------------------------------------------------
log_title "Ressources"
MEM_MB=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
if (( MEM_MB >= MIN_MEMORY_MB )); then
    check_ok "Mémoire : ${MEM_MB} Mo (minimum ${MIN_MEMORY_MB} Mo)"
else
    check_warn "Mémoire faible : ${MEM_MB} Mo (minimum conseillé ${MIN_MEMORY_MB} Mo)"
fi

# Espace disque : on remonte jusqu'au premier parent existant du répertoire
existing_parent() {
    local d="$1"
    while [[ ! -d "${d}" && "${d}" != "/" ]]; do d="$(dirname "${d}")"; done
    echo "${d}"
}
for dir in "${PROMETHEUS_DATA_DIR}" "${ALERTMANAGER_DATA_DIR}" "${BIN_DIR}"; do
    parent="$(existing_parent "${dir}")"
    free_mb=$(df -Pm "${parent}" 2>/dev/null | awk 'NR==2 {print $4}')
    free_mb=${free_mb:-0}
    if [[ "${dir}" == "${PROMETHEUS_DATA_DIR}" ]]; then
        required=${MIN_DISK_MB}
    else
        required=200
    fi
    if (( free_mb >= required )); then
        check_ok "Espace libre pour ${dir} : ${free_mb} Mo (minimum ${required} Mo)"
    else
        check_fail "Espace insuffisant pour ${dir} : ${free_mb} Mo (minimum ${required} Mo)"
    fi
done

# --- 5. Ports réseau ---------------------------------------------------------
log_title "Ports réseau"
for entry in "Prometheus:${PROMETHEUS_PORT}" "Alertmanager:${ALERTMANAGER_PORT}"; do
    name="${entry%%:*}"; port="${entry##*:}"
    if ! [[ "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        check_fail "Port ${name} invalide : ${port}"
    elif port_in_use "${port}"; then
        svc="${name,,}"
        if cmd_exists systemctl && systemctl is-active --quiet "${svc}" 2>/dev/null; then
            check_warn "Port ${port} utilisé par le service ${svc} déjà actif (réinstallation ?)"
        else
            check_fail "Port ${port} (${name}) déjà utilisé par un autre processus"
        fi
    else
        check_ok "Port ${port} (${name}) libre"
    fi
done

# --- 6. Installation existante -----------------------------------------------
log_title "Installation existante"
EXISTING=0
for f in "${BIN_DIR}/prometheus" "${BIN_DIR}/promtool" \
         "${BIN_DIR}/alertmanager" "${BIN_DIR}/amtool" \
         "${SYSTEMD_DIR}/prometheus.service" "${SYSTEMD_DIR}/alertmanager.service"; do
    if [[ -e "${f}" ]]; then
        log_warn "Présent : ${f}"
        EXISTING=1
    fi
done
for d in "${PROMETHEUS_CONF_DIR}" "${PROMETHEUS_DATA_DIR}" \
         "${ALERTMANAGER_CONF_DIR}" "${ALERTMANAGER_DATA_DIR}"; do
    if [[ -d "${d}" ]] && [[ -n "$(ls -A "${d}" 2>/dev/null)" ]]; then
        log_warn "Répertoire non vide : ${d}"
        EXISTING=1
    fi
done
for u in "${PROMETHEUS_USER}" "${ALERTMANAGER_USER}"; do
    if getent passwd "${u}" >/dev/null 2>&1; then
        log_info "Compte système déjà présent : ${u} (sera réutilisé)"
    fi
done
if (( EXISTING )); then
    if [[ -x "${BIN_DIR}/prometheus" ]]; then
        log_info "Version installée : $("${BIN_DIR}/prometheus" --version 2>&1 | head -n1)"
    fi
    if [[ -x "${BIN_DIR}/alertmanager" ]]; then
        log_info "Version installée : $("${BIN_DIR}/alertmanager" --version 2>&1 | head -n1)"
    fi
    check_warn "Une installation précédente existe : lancez 99_nettoyage.sh pour repartir de zéro, ou 01_installation.sh --force pour la mettre à jour"
else
    check_ok "Aucune installation précédente détectée"
fi

# --- 7. Disponibilité des archives -------------------------------------------
log_title "Archives d'installation"
if [[ "${ARCH}" != "unsupported" ]]; then
    for comp in prometheus alertmanager; do
        archive="$(archive_basename "${comp}").tar.gz"
        if [[ -f "${PACKAGES_DIR}/${archive}" ]]; then
            if tar -tzf "${PACKAGES_DIR}/${archive}" >/dev/null 2>&1; then
                check_ok "Archive locale valide : packages/${archive}"
            else
                check_fail "Archive locale corrompue : packages/${archive}"
            fi
        elif [[ "${OFFLINE}" == "yes" ]]; then
            check_fail "Mode hors-ligne : archive absente de packages/ : ${archive}"
        else
            url="$(release_url "${comp}" "${archive}")"
            if url_reachable "${url}"; then
                check_ok "Archive téléchargeable : ${url}"
            else
                check_fail "Archive ni présente dans packages/ ni téléchargeable : ${url}"
            fi
        fi
    done
fi

# --- 8. Sécurité / pare-feu (informatif) -------------------------------------
log_title "Sécurité et pare-feu"
if cmd_exists getenforce; then
    selinux="$(getenforce 2>/dev/null)"
    if [[ "${selinux}" == "Enforcing" ]]; then
        log_info "SELinux en mode Enforcing : les contextes seront restaurés (restorecon) à l'installation"
    else
        log_info "SELinux : ${selinux}"
    fi
fi
if cmd_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    log_info "firewalld actif (OPEN_FIREWALL=${OPEN_FIREWALL})"
elif cmd_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    log_info "ufw actif (OPEN_FIREWALL=${OPEN_FIREWALL})"
else
    log_info "Aucun pare-feu local géré détecté (firewalld/ufw)"
fi

# --- Bilan -------------------------------------------------------------------
log_title "Bilan"
if (( ERRORS > 0 )); then
    log_error "${ERRORS} erreur(s), ${WARNINGS} avertissement(s) : le système n'est PAS prêt."
    exit 1
fi
log_ok "0 erreur, ${WARNINGS} avertissement(s) : le système est prêt pour l'installation."
exit 0
