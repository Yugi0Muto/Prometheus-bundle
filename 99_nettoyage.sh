#!/usr/bin/env bash
# =============================================================================
#  99 - Nettoyage d'une installation précédente
# -----------------------------------------------------------------------------
#  Supprime Prometheus et Alertmanager : services, binaires, configurations,
#  données, comptes système et règles de pare-feu ouvertes par le bundle.
#
#  Usage : sudo ./99_nettoyage.sh [options]
#    -y, --yes        Pas de confirmation interactive
#    --backup         Archive configurations (et données si supprimées) avant
#                     suppression dans /var/backups/prometheus-bundle/
#    --keep-data      Conserve les répertoires de données (TSDB, silences)
#    --keep-config    Conserve les répertoires de configuration
#    --keep-users     Conserve les comptes et groupes système
#    -h, --help       Affiche cette aide
# =============================================================================
set -uo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

BACKUP="no"
KEEP_DATA="no"
KEEP_CONFIG="no"
KEEP_USERS="no"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/prometheus-bundle}"

usage() {
    sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^#  \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)      ASSUME_YES="yes" ;;
        --backup)      BACKUP="yes" ;;
        --keep-data)   KEEP_DATA="yes" ;;
        --keep-config) KEEP_CONFIG="yes" ;;
        --keep-users)  KEEP_USERS="yes" ;;
        -h|--help)     usage ;;
        *) die "Option inconnue : $1 (voir --help)" ;;
    esac
    shift
done

require_root
init_log "99_nettoyage"

FAILURES=0
# run <description> <commande...> : exécute sans interrompre le nettoyage
run() {
    local desc="$1"; shift
    if "$@"; then
        log_ok "${desc}"
    else
        log_warn "Échec : ${desc}"
        FAILURES=$((FAILURES + 1))
    fi
}

log_title "99 - Nettoyage de l'installation Prometheus / Alertmanager"

# --- Inventaire --------------------------------------------------------------
BINARIES=("${BIN_DIR}/prometheus" "${BIN_DIR}/promtool"
          "${BIN_DIR}/alertmanager" "${BIN_DIR}/amtool")
UNITS=("${SYSTEMD_DIR}/prometheus.service" "${SYSTEMD_DIR}/alertmanager.service")
CONF_DIRS=("${PROMETHEUS_CONF_DIR}" "${ALERTMANAGER_CONF_DIR}")
DATA_DIRS=("${PROMETHEUS_DATA_DIR}" "${ALERTMANAGER_DATA_DIR}")

# Garde-fou : refuse de supprimer des chemins système critiques
for d in "${CONF_DIRS[@]}" "${DATA_DIRS[@]}"; do
    case "${d%/}" in
        ""|/|/etc|/var|/var/lib|/usr|/usr/local|/home|/root|/opt|/bin|/sbin)
            die "Chemin dangereux refusé dans la configuration : '${d}'" ;;
    esac
done

echo "Éléments ciblés :"
for f in "${UNITS[@]}" "${BINARIES[@]}"; do
    [[ -e "${f}" ]] && echo "  - ${f}"
done
if [[ "${KEEP_CONFIG}" != "yes" ]]; then
    for d in "${CONF_DIRS[@]}"; do [[ -d "${d}" ]] && echo "  - ${d}/ (configuration)"; done
fi
if [[ "${KEEP_DATA}" != "yes" ]]; then
    for d in "${DATA_DIRS[@]}"; do
        [[ -d "${d}" ]] && echo "  - ${d}/ (données, $(du -sh "${d}" 2>/dev/null | cut -f1))"
    done
fi
if [[ "${KEEP_USERS}" != "yes" ]]; then
    for u in "${PROMETHEUS_USER}" "${ALERTMANAGER_USER}"; do
        getent passwd "${u}" >/dev/null 2>&1 && echo "  - compte système ${u}"
    done
fi
echo

if ! confirm "Confirmez-vous la suppression définitive de ces éléments ?"; then
    log_info "Nettoyage annulé."
    exit 0
fi

# --- 1. Sauvegarde -----------------------------------------------------------
if [[ "${BACKUP}" == "yes" ]]; then
    log_title "Sauvegarde"
    to_save=()
    for d in "${CONF_DIRS[@]}"; do [[ -d "${d}" ]] && to_save+=("${d}"); done
    if [[ "${KEEP_DATA}" != "yes" ]]; then
        for d in "${DATA_DIRS[@]}"; do [[ -d "${d}" ]] && to_save+=("${d}"); done
    fi
    for f in "${UNITS[@]}"; do [[ -f "${f}" ]] && to_save+=("${f}"); done
    if (( ${#to_save[@]} > 0 )); then
        mkdir -p "${BACKUP_DIR}"
        archive="${BACKUP_DIR}/sauvegarde_$(date +%Y%m%d_%H%M%S).tar.gz"
        if tar -czPf "${archive}" "${to_save[@]}"; then
            log_ok "Sauvegarde créée : ${archive}"
        else
            die "Échec de la sauvegarde : nettoyage interrompu, rien n'a été supprimé."
        fi
    else
        log_info "Rien à sauvegarder"
    fi
fi

# --- 2. Services -------------------------------------------------------------
log_title "Services"
for svc in prometheus alertmanager; do
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
        run "Service ${svc} arrêté" systemctl stop "${svc}"
    fi
    if systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
        run "Service ${svc} désactivé" systemctl disable "${svc}"
    fi
done
for f in "${UNITS[@]}"; do
    [[ -e "${f}" ]] && run "Unité supprimée : ${f}" rm -f "${f}"
    # Surcharges éventuelles créées par systemctl edit
    [[ -d "${f}.d" ]] && run "Surcharges supprimées : ${f}.d" rm -rf "${f}.d"
done
if cmd_exists systemctl; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed prometheus.service alertmanager.service 2>/dev/null || true
fi

# Processus résiduels lancés hors systemd
for proc in prometheus alertmanager; do
    if pgrep -x "${proc}" >/dev/null 2>&1; then
        log_warn "Processus ${proc} encore actif hors systemd : arrêt"
        pkill -TERM -x "${proc}" || true
        sleep 3
        pgrep -x "${proc}" >/dev/null 2>&1 && pkill -KILL -x "${proc}"
    fi
done

# --- 3. Binaires -------------------------------------------------------------
log_title "Binaires"
for f in "${BINARIES[@]}"; do
    [[ -e "${f}" ]] && run "Supprimé : ${f}" rm -f "${f}"
done

# --- 4. Configurations et données --------------------------------------------
log_title "Configurations et données"
if [[ "${KEEP_CONFIG}" == "yes" ]]; then
    log_info "Configurations conservées (--keep-config)"
else
    for d in "${CONF_DIRS[@]}"; do
        [[ -d "${d}" ]] && run "Supprimé : ${d}" rm -rf "${d}"
    done
fi
if [[ "${KEEP_DATA}" == "yes" ]]; then
    log_info "Données conservées (--keep-data)"
else
    for d in "${DATA_DIRS[@]}"; do
        [[ -d "${d}" ]] && run "Supprimé : ${d}" rm -rf "${d}"
    done
fi

# --- 5. Pare-feu -------------------------------------------------------------
log_title "Pare-feu"
if cmd_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    changed="no"
    for port in "${PROMETHEUS_PORT}" "${ALERTMANAGER_PORT}"; do
        if firewall-cmd --permanent --query-port="${port}/tcp" >/dev/null 2>&1; then
            run "firewalld : port ${port}/tcp fermé" \
                firewall-cmd --permanent --remove-port="${port}/tcp" --quiet
            changed="yes"
        fi
    done
    [[ "${changed}" == "yes" ]] && firewall-cmd --reload >/dev/null 2>&1
elif cmd_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    for port in "${PROMETHEUS_PORT}" "${ALERTMANAGER_PORT}"; do
        if ufw status 2>/dev/null | grep -q "^${port}/tcp"; then
            run "ufw : règle ${port}/tcp supprimée" ufw --force delete allow "${port}/tcp"
        fi
    done
else
    log_info "Aucun pare-feu firewalld/ufw actif"
fi

# --- 6. Comptes système ------------------------------------------------------
log_title "Comptes système"
if [[ "${KEEP_USERS}" == "yes" ]]; then
    log_info "Comptes conservés (--keep-users)"
else
    for u in "${PROMETHEUS_USER}" "${ALERTMANAGER_USER}"; do
        if getent passwd "${u}" >/dev/null 2>&1; then
            run "Utilisateur supprimé : ${u}" userdel "${u}"
        fi
    done
    for g in "${PROMETHEUS_GROUP}" "${ALERTMANAGER_GROUP}"; do
        if getent group "${g}" >/dev/null 2>&1; then
            run "Groupe supprimé : ${g}" groupdel "${g}"
        fi
    done
fi

# --- Bilan -------------------------------------------------------------------
log_title "Bilan"
if (( FAILURES > 0 )); then
    log_error "Nettoyage terminé avec ${FAILURES} échec(s) : consultez le journal ci-dessus."
    exit 1
fi
log_ok "Nettoyage terminé : le système est prêt pour une nouvelle installation."
