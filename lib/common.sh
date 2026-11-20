#!/usr/bin/env bash
# =============================================================================
#  Prometheus-bundle - Fonctions communes
#  Ce fichier est sourcé par les scripts 00, 01 et 99 ; il ne s'exécute pas seul.
# =============================================================================

# Répertoire racine du bundle (parent de lib/)
BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export BUNDLE_DIR

# shellcheck source=config/bundle.conf
. "${BUNDLE_DIR}/config/bundle.conf"

# shellcheck disable=SC2034  # utilisées par les scripts qui sourcent ce fichier
PACKAGES_DIR="${BUNDLE_DIR}/packages"
# shellcheck disable=SC2034
TEMPLATES_DIR="${BUNDLE_DIR}/templates"

# --- Couleurs (désactivées si la sortie n'est pas un terminal) ---------------
if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
    C_BLUE=$'\e[34m'; C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

# --- Journalisation ----------------------------------------------------------
LOG_FILE=""

# init_log <nom_script> : duplique la sortie vers un fichier de log horodaté
init_log() {
    local name="$1"
    if mkdir -p "${LOG_DIR}" 2>/dev/null && [[ -w "${LOG_DIR}" ]]; then
        LOG_FILE="${LOG_DIR}/${name}_$(date +%Y%m%d_%H%M%S).log"
        exec > >(tee -a "${LOG_FILE}") 2>&1
        log_info "Journal : ${LOG_FILE}"
    fi
}

_ts()        { date '+%Y-%m-%d %H:%M:%S'; }
log_info()   { printf '%s %s[INFO]%s  %s\n' "$(_ts)" "${C_BLUE}"   "${C_RESET}" "$*"; }
log_ok()     { printf '%s %s[OK]%s    %s\n' "$(_ts)" "${C_GREEN}"  "${C_RESET}" "$*"; }
log_warn()   { printf '%s %s[WARN]%s  %s\n' "$(_ts)" "${C_YELLOW}" "${C_RESET}" "$*"; }
log_error()  { printf '%s %s[ERROR]%s %s\n' "$(_ts)" "${C_RED}"    "${C_RESET}" "$*" >&2; }
log_title()  { printf '\n%s==== %s ====%s\n' "${C_BOLD}" "$*" "${C_RESET}"; }

die() { log_error "$*"; exit 1; }

# --- Pré-requis d'exécution --------------------------------------------------
require_root() {
    [[ ${EUID} -eq 0 ]] || die "Ce script doit être exécuté en tant que root (sudo)."
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# confirm "<question>" : renvoie 0 si l'utilisateur répond oui
# Respecte ASSUME_YES=yes pour le mode non interactif.
confirm() {
    [[ "${ASSUME_YES:-no}" == "yes" ]] && return 0
    local answer
    read -r -p "$1 [o/N] " answer
    [[ "${answer,,}" =~ ^(o|oui|y|yes)$ ]]
}

# --- Détection système -------------------------------------------------------
# Renvoie l'architecture au format des releases Prometheus (amd64, arm64...)
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        armv7l|armv7)   echo "armv7" ;;
        armv6l)         echo "armv6" ;;
        i386|i686)      echo "386" ;;
        ppc64le)        echo "ppc64le" ;;
        s390x)          echo "s390x" ;;
        *)              echo "unsupported" ;;
    esac
}

# Affiche "ID VERSION_ID" depuis /etc/os-release
detect_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        ( . /etc/os-release; echo "${ID:-inconnu} ${VERSION_ID:-?}" )
    else
        echo "inconnu ?"
    fi
}

# Nom de l'archive / du répertoire extrait pour un composant
# archive_basename <prometheus|alertmanager>
archive_basename() {
    local comp="$1" version
    case "${comp}" in
        prometheus)   version="${PROMETHEUS_VERSION}" ;;
        alertmanager) version="${ALERTMANAGER_VERSION}" ;;
        *) die "Composant inconnu : ${comp}" ;;
    esac
    echo "${comp}-${version}.linux-$(detect_arch)"
}

# URL de téléchargement d'un fichier de release
# release_url <composant> <fichier>
release_url() {
    local comp="$1" file="$2" version
    case "${comp}" in
        prometheus)   version="${PROMETHEUS_VERSION}" ;;
        alertmanager) version="${ALERTMANAGER_VERSION}" ;;
    esac
    echo "${DOWNLOAD_BASE_URL}/${comp}/releases/download/v${version}/${file}"
}

# Téléchargement générique (curl ou wget)
download() {
    local url="$1" dest="$2"
    if cmd_exists curl; then
        curl -fSL --retry 3 --connect-timeout 15 -o "${dest}" "${url}"
    elif cmd_exists wget; then
        wget -q --tries=3 --timeout=15 -O "${dest}" "${url}"
    else
        log_error "Ni curl ni wget n'est disponible."
        return 1
    fi
}

# Test de connectivité HTTP(S) vers une URL (code < 400 attendu)
url_reachable() {
    local url="$1"
    if cmd_exists curl; then
        curl -fsIL --connect-timeout 10 -o /dev/null "${url}"
    elif cmd_exists wget; then
        wget -q --spider --timeout=10 "${url}"
    else
        return 1
    fi
}

# Port TCP en écoute ? port_in_use <port>
port_in_use() {
    local port="$1"
    if cmd_exists ss; then
        ss -Htln "sport = :${port}" 2>/dev/null | grep -q .
    elif cmd_exists netstat; then
        netstat -tln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}\$"
    else
        # Repli : tentative de connexion via /dev/tcp
        (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null
    fi
}

# Le service systemd existe-t-il ?
service_exists() {
    systemctl list-unit-files --type=service 2>/dev/null | grep -q "^$1\.service"
}

# --- Gabarits ----------------------------------------------------------------
# render_template <source> <destination>
# Remplace chaque @@VARIABLE@@ par la valeur de la variable shell VARIABLE.
render_template() {
    local src="$1" dst="$2" content var value
    [[ -r "${src}" ]] || die "Gabarit introuvable : ${src}"
    content="$(<"${src}")"
    while read -r var; do
        [[ -n "${var}" ]] || continue
        [[ -v "${var}" ]] || die "Variable '${var}' non définie (gabarit ${src})."
        value="${!var}"
        # Remplacement entre guillemets : '&' n'est pas interprété (bash >= 5.2)
        content="${content//"@@${var}@@"/"${value}"}"
    done < <(grep -o '@@[A-Z0-9_]\+@@' "${src}" | tr -d '@' | sort -u)
    printf '%s\n' "${content}" > "${dst}"
}

# --- Attente de disponibilité HTTP -------------------------------------------
# wait_http_ready <url> <timeout_secondes>
wait_http_ready() {
    local url="$1" timeout="${2:-30}" i
    for ((i = 0; i < timeout; i++)); do
        if url_reachable "${url}"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# Adresse à utiliser pour les tests locaux (0.0.0.0 -> 127.0.0.1)
local_address() {
    local addr="$1"
    [[ "${addr}" == "0.0.0.0" || -z "${addr}" ]] && addr="127.0.0.1"
    echo "${addr}"
}
