#!/usr/bin/env bash
# =============================================================================
#  01 - Installation de Prometheus et Alertmanager
# -----------------------------------------------------------------------------
#  Usage : sudo ./01_installation.sh [options]
#    --force         Écrase les binaires et configurations existants
#                    (une sauvegarde .bak.<date> des configurations est faite)
#    --skip-checks   Ne lance pas 00_verification_prealable.sh
#    --no-start      Installe sans démarrer les services
#    -h, --help      Affiche cette aide
# =============================================================================
set -Eeuo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

FORCE="no"
SKIP_CHECKS="no"
START_SERVICES="yes"

usage() {
    sed -n '3,10p' "${BASH_SOURCE[0]}" | sed 's/^#  \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)       FORCE="yes" ;;
        --skip-checks) SKIP_CHECKS="yes" ;;
        --no-start)    START_SERVICES="no" ;;
        -h|--help)     usage ;;
        *) die "Option inconnue : $1 (voir --help)" ;;
    esac
    shift
done

require_root
init_log "01_installation"

WORK_DIR="$(mktemp -d /tmp/prometheus-bundle.XXXXXX)"
cleanup_tmp() { rm -rf "${WORK_DIR}"; }
trap cleanup_tmp EXIT
trap 'log_error "Échec à la ligne ${LINENO} : ${BASH_COMMAND}"' ERR

# Cibles utilisées dans les gabarits
PROMETHEUS_TARGET="$(local_address "${PROMETHEUS_LISTEN_ADDRESS}"):${PROMETHEUS_PORT}"
ALERTMANAGER_TARGET="$(local_address "${ALERTMANAGER_LISTEN_ADDRESS}"):${ALERTMANAGER_PORT}"
export PROMETHEUS_TARGET ALERTMANAGER_TARGET

log_title "01 - Installation Prometheus ${PROMETHEUS_VERSION} / Alertmanager ${ALERTMANAGER_VERSION}"

# --- Étape 1 : vérifications préliminaires -----------------------------------
if [[ "${SKIP_CHECKS}" == "yes" ]]; then
    log_warn "Vérifications préliminaires ignorées (--skip-checks)"
else
    log_info "Lancement de 00_verification_prealable.sh"
    if ! BUNDLE_SKIP_LOG=yes bash "${BUNDLE_DIR}/00_verification_prealable.sh"; then
        die "Les vérifications préliminaires ont échoué. Corrigez les erreurs ou utilisez --skip-checks."
    fi
fi

# Refus d'écraser une installation existante sans --force
if [[ "${FORCE}" != "yes" ]]; then
    for f in "${BIN_DIR}/prometheus" "${BIN_DIR}/alertmanager"; do
        if [[ -e "${f}" ]]; then
            die "${f} existe déjà. Utilisez --force pour mettre à jour, ou 99_nettoyage.sh."
        fi
    done
fi

# --- Étape 2 : récupération des archives -------------------------------------
# fetch_archive <composant> : place l'archive vérifiée dans WORK_DIR
fetch_archive() {
    local comp="$1" base archive sums_local
    base="$(archive_basename "${comp}")"
    archive="${base}.tar.gz"
    sums_local="${PACKAGES_DIR}/${comp}-sha256sums.txt"

    if [[ -f "${PACKAGES_DIR}/${archive}" ]]; then
        log_info "Archive locale : packages/${archive}"
        cp "${PACKAGES_DIR}/${archive}" "${WORK_DIR}/"
    elif [[ "${OFFLINE}" == "yes" ]]; then
        die "Mode hors-ligne et archive absente : packages/${archive}"
    else
        log_info "Téléchargement de ${archive}"
        download "$(release_url "${comp}" "${archive}")" "${WORK_DIR}/${archive}" \
            || die "Téléchargement impossible : ${archive}"
    fi

    if [[ "${VERIFY_CHECKSUM}" == "yes" ]]; then
        if [[ -f "${sums_local}" ]]; then
            cp "${sums_local}" "${WORK_DIR}/${comp}-sha256sums.txt"
        elif [[ "${OFFLINE}" != "yes" ]]; then
            download "$(release_url "${comp}" sha256sums.txt)" "${WORK_DIR}/${comp}-sha256sums.txt" \
                || die "Impossible de récupérer sha256sums.txt pour ${comp} (VERIFY_CHECKSUM=no pour ignorer)"
        else
            die "Mode hors-ligne : placez packages/${comp}-sha256sums.txt ou positionnez VERIFY_CHECKSUM=no"
        fi
        local expected actual
        expected="$(awk -v f="${archive}" '$2 == f || $2 == "*"f {print $1}' "${WORK_DIR}/${comp}-sha256sums.txt")"
        [[ -n "${expected}" ]] || die "Somme de contrôle introuvable pour ${archive}"
        actual="$(sha256sum "${WORK_DIR}/${archive}" | awk '{print $1}')"
        [[ "${expected}" == "${actual}" ]] || die "Somme SHA256 incorrecte pour ${archive}"
        log_ok "Somme SHA256 vérifiée : ${archive}"
    else
        log_warn "Vérification SHA256 désactivée (VERIFY_CHECKSUM=no)"
    fi

    tar -xzf "${WORK_DIR}/${archive}" -C "${WORK_DIR}"
    [[ -d "${WORK_DIR}/${base}" ]] || die "Contenu inattendu dans ${archive} (répertoire ${base} absent)"
    log_ok "Archive extraite : ${base}"
}

log_title "Récupération des archives"
fetch_archive prometheus
fetch_archive alertmanager
PROM_SRC="${WORK_DIR}/$(archive_basename prometheus)"
AM_SRC="${WORK_DIR}/$(archive_basename alertmanager)"

# --- Étape 3 : comptes système -----------------------------------------------
# create_account <utilisateur> <groupe> <home>
create_account() {
    local user="$1" group="$2" home="$3" nologin
    nologin="$(command -v nologin || echo /sbin/nologin)"
    if ! getent group "${group}" >/dev/null; then
        groupadd --system "${group}"
        log_ok "Groupe créé : ${group}"
    else
        log_info "Groupe existant : ${group}"
    fi
    if ! getent passwd "${user}" >/dev/null; then
        useradd --system --gid "${group}" --no-create-home \
                --home-dir "${home}" --shell "${nologin}" \
                --comment "Compte de service ${user}" "${user}"
        log_ok "Utilisateur créé : ${user}"
    else
        log_info "Utilisateur existant : ${user}"
    fi
}

log_title "Comptes système"
create_account "${PROMETHEUS_USER}" "${PROMETHEUS_GROUP}" "${PROMETHEUS_DATA_DIR}"
create_account "${ALERTMANAGER_USER}" "${ALERTMANAGER_GROUP}" "${ALERTMANAGER_DATA_DIR}"

# --- Étape 4 : arborescence --------------------------------------------------
log_title "Arborescence"
install -d -m 0755 -o root -g "${PROMETHEUS_GROUP}" \
    "${PROMETHEUS_CONF_DIR}" "${PROMETHEUS_CONF_DIR}/rules"
install -d -m 0750 -o "${PROMETHEUS_USER}" -g "${PROMETHEUS_GROUP}" "${PROMETHEUS_DATA_DIR}"
install -d -m 0755 -o root -g "${ALERTMANAGER_GROUP}" "${ALERTMANAGER_CONF_DIR}"
install -d -m 0750 -o "${ALERTMANAGER_USER}" -g "${ALERTMANAGER_GROUP}" "${ALERTMANAGER_DATA_DIR}"
install -d -m 0755 "${BIN_DIR}"
log_ok "Répertoires créés"

# --- Étape 5 : binaires ------------------------------------------------------
log_title "Binaires"
# Arrêt des services en cours avant remplacement des binaires (--force)
for svc in prometheus alertmanager; do
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
        log_info "Arrêt du service ${svc} pour mise à jour"
        systemctl stop "${svc}"
    fi
done
install -m 0755 -o root -g root "${PROM_SRC}/prometheus"   "${BIN_DIR}/prometheus"
install -m 0755 -o root -g root "${PROM_SRC}/promtool"     "${BIN_DIR}/promtool"
install -m 0755 -o root -g root "${AM_SRC}/alertmanager"   "${BIN_DIR}/alertmanager"
install -m 0755 -o root -g root "${AM_SRC}/amtool"         "${BIN_DIR}/amtool"
log_ok "$("${BIN_DIR}/prometheus" --version 2>&1 | head -n1)"
log_ok "$("${BIN_DIR}/alertmanager" --version 2>&1 | head -n1)"

# Prometheus 2.x fournit encore consoles/ et console_libraries/
for d in consoles console_libraries; do
    if [[ -d "${PROM_SRC}/${d}" ]]; then
        cp -r "${PROM_SRC}/${d}" "${PROMETHEUS_CONF_DIR}/"
    fi
done

# --- Étape 6 : configuration -------------------------------------------------
# deploy_file <source> <destination> <propriétaire:groupe> <mode> [template]
deploy_file() {
    local src="$1" dst="$2" owner="$3" mode="$4" is_tpl="${5:-}"
    if [[ -e "${dst}" ]]; then
        if [[ "${FORCE}" != "yes" ]]; then
            log_info "Conservé (existant) : ${dst}"
            return 0
        fi
        cp -p "${dst}" "${dst}.bak.$(date +%Y%m%d_%H%M%S)"
        log_info "Sauvegarde : ${dst}.bak.*"
    fi
    if [[ "${is_tpl}" == "template" ]]; then
        render_template "${src}" "${dst}"
    else
        cp "${src}" "${dst}"
    fi
    chown "${owner}" "${dst}"
    chmod "${mode}" "${dst}"
    log_ok "Déployé : ${dst}"
}

log_title "Configuration"
case "${ALERTMANAGER_RECEIVER_TYPE}" in
    webhook|email) ;;
    *) die "ALERTMANAGER_RECEIVER_TYPE invalide : ${ALERTMANAGER_RECEIVER_TYPE} (webhook|email)" ;;
esac

deploy_file "${TEMPLATES_DIR}/prometheus.yml.tpl" \
    "${PROMETHEUS_CONF_DIR}/prometheus.yml" "root:${PROMETHEUS_GROUP}" 0640 template
for rule in "${TEMPLATES_DIR}"/rules/*.yml; do
    deploy_file "${rule}" "${PROMETHEUS_CONF_DIR}/rules/$(basename "${rule}")" \
        "root:${PROMETHEUS_GROUP}" 0640
done
deploy_file "${TEMPLATES_DIR}/alertmanager-${ALERTMANAGER_RECEIVER_TYPE}.yml.tpl" \
    "${ALERTMANAGER_CONF_DIR}/alertmanager.yml" "root:${ALERTMANAGER_GROUP}" 0640 template

# Validation syntaxique
log_info "Validation des configurations"
"${BIN_DIR}/promtool" check config "${PROMETHEUS_CONF_DIR}/prometheus.yml" \
    || die "Configuration Prometheus invalide"
"${BIN_DIR}/amtool" check-config "${ALERTMANAGER_CONF_DIR}/alertmanager.yml" \
    || die "Configuration Alertmanager invalide"
log_ok "Configurations valides"

# --- Étape 7 : services systemd ----------------------------------------------
log_title "Services systemd"
# Les unités sont toujours régénérées : elles reflètent bundle.conf
for svc in prometheus alertmanager; do
    render_template "${TEMPLATES_DIR}/systemd/${svc}.service.tpl" "${SYSTEMD_DIR}/${svc}.service"
    chmod 0644 "${SYSTEMD_DIR}/${svc}.service"
    log_ok "Unité déployée : ${SYSTEMD_DIR}/${svc}.service"
done

# SELinux : restauration des contextes sur les fichiers déployés
if cmd_exists restorecon && cmd_exists getenforce && [[ "$(getenforce)" != "Disabled" ]]; then
    restorecon -R "${BIN_DIR}/prometheus" "${BIN_DIR}/promtool" \
        "${BIN_DIR}/alertmanager" "${BIN_DIR}/amtool" \
        "${PROMETHEUS_CONF_DIR}" "${ALERTMANAGER_CONF_DIR}" \
        "${PROMETHEUS_DATA_DIR}" "${ALERTMANAGER_DATA_DIR}" \
        "${SYSTEMD_DIR}/prometheus.service" "${SYSTEMD_DIR}/alertmanager.service" || true
    log_ok "Contextes SELinux restaurés"
fi

systemctl daemon-reload
systemctl enable alertmanager prometheus
log_ok "Services activés au démarrage"

# --- Étape 8 : pare-feu (optionnel) ------------------------------------------
if [[ "${OPEN_FIREWALL}" == "yes" ]]; then
    log_title "Pare-feu"
    if cmd_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${PROMETHEUS_PORT}/tcp" \
                                 --add-port="${ALERTMANAGER_PORT}/tcp" >/dev/null
        firewall-cmd --reload >/dev/null
        log_ok "firewalld : ports ${PROMETHEUS_PORT}/tcp et ${ALERTMANAGER_PORT}/tcp ouverts"
    elif cmd_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${PROMETHEUS_PORT}/tcp" comment "prometheus" >/dev/null
        ufw allow "${ALERTMANAGER_PORT}/tcp" comment "alertmanager" >/dev/null
        log_ok "ufw : ports ${PROMETHEUS_PORT}/tcp et ${ALERTMANAGER_PORT}/tcp ouverts"
    else
        log_warn "OPEN_FIREWALL=yes mais aucun pare-feu firewalld/ufw actif"
    fi
fi

# --- Étape 9 : démarrage et contrôle de santé --------------------------------
if [[ "${START_SERVICES}" == "yes" ]]; then
    log_title "Démarrage"
    systemctl restart alertmanager
    systemctl restart prometheus

    AM_URL="http://${ALERTMANAGER_TARGET}/-/ready"
    PROM_URL="http://${PROMETHEUS_TARGET}/-/ready"
    HEALTH_OK="yes"
    if wait_http_ready "${AM_URL}" 30; then
        log_ok "Alertmanager prêt : ${AM_URL}"
    else
        log_error "Alertmanager ne répond pas (journalctl -u alertmanager)"
        HEALTH_OK="no"
    fi
    if wait_http_ready "${PROM_URL}" 60; then
        log_ok "Prometheus prêt : ${PROM_URL}"
    else
        log_error "Prometheus ne répond pas (journalctl -u prometheus)"
        HEALTH_OK="no"
    fi
    [[ "${HEALTH_OK}" == "yes" ]] || die "Installation terminée mais au moins un service n'est pas opérationnel."
else
    log_warn "Services non démarrés (--no-start) : systemctl start alertmanager prometheus"
fi

# --- Bilan -------------------------------------------------------------------
log_title "Installation terminée"
cat <<EOF
  Prometheus   : http://$(hostname -f 2>/dev/null || hostname):${PROMETHEUS_PORT}
  Alertmanager : http://$(hostname -f 2>/dev/null || hostname):${ALERTMANAGER_PORT}

  Configurations : ${PROMETHEUS_CONF_DIR}/prometheus.yml
                   ${PROMETHEUS_CONF_DIR}/rules/
                   ${ALERTMANAGER_CONF_DIR}/alertmanager.yml
  Données        : ${PROMETHEUS_DATA_DIR}  |  ${ALERTMANAGER_DATA_DIR}
  Journaux       : journalctl -u prometheus -u alertmanager
  Rechargement   : systemctl reload prometheus | systemctl reload alertmanager
  Désinstallation: ./99_nettoyage.sh
EOF
