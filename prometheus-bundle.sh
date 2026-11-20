#!/usr/bin/env bash
# =============================================================================
#  PROMETHEUS-BUNDLE
#  Supervision applicative : Prometheus + Alertmanager + agents + Grafana
# -----------------------------------------------------------------------------
#  Script unique et autonome : toute la configuration est dans la section
#  « CONFIGURATION » ci-dessous (aucun fichier externe).
#
#  Usage :
#    sudo ./prometheus-bundle.sh                 Menu interactif
#    sudo ./prometheus-bundle.sh <étape> [...]   Mode commande
#
#  Étapes :
#    00  verification   Vérification préliminaire (ne modifie rien)
#    01  installation   Installation de Prometheus et Alertmanager
#    02  configuration  Paramètres et seuils : afficher / modifier / appliquer
#    03  agents         Supervision des applications (agents et cibles)
#    04  alerting       Canaux d'alerte (Slack, Teams, Telegram, e-mail...)
#    05  grafana        Grafana + tableaux de bord (sur cette machine ou une autre)
#    06  exploitation   État, alertes, maintenance (silences), rechargement
#    07  sauvegarde     Sauvegarde et restauration de la configuration
#    08  test           Test des alertes d'une application (règles + envoi simulé)
#    99  nettoyage      Suppression d'une installation précédente
#
#  Aide détaillée d'une étape :  ./prometheus-bundle.sh <étape> aide
#  Guide d'exploitation       :  docs/GUIDE_EXPLOITATION.md
# =============================================================================
# shellcheck disable=SC2034,SC2155  # variables lues par substitution indirecte (gabarits @@VAR@@)
set -uo pipefail

# =============================================================================
#  CONFIGURATION
# -----------------------------------------------------------------------------
#  Chaque valeur peut être :
#   - modifiée ici directement,
#   - modifiée avec : ./prometheus-bundle.sh 02 definir <VARIABLE> <valeur>
#     (le script se met à jour lui-même puis réapplique la configuration),
#   - surchargée ponctuellement par l'environnement :
#     PROMETHEUS_PORT=9091 ./prometheus-bundle.sh 01
# =============================================================================

# --- Versions des composants -------------------------------------------------
: "${PROMETHEUS_VERSION:=3.16.0}"
: "${ALERTMANAGER_VERSION:=0.35.0}"
: "${NODE_EXPORTER_VERSION:=1.13.1}"
: "${BLACKBOX_EXPORTER_VERSION:=0.29.1}"
: "${MYSQLD_EXPORTER_VERSION:=0.21.0}"
: "${POSTGRES_EXPORTER_VERSION:=0.21.1}"
: "${REDIS_EXPORTER_VERSION:=1.97.0}"
: "${MONGODB_EXPORTER_VERSION:=0.54.0}"
: "${NGINX_EXPORTER_VERSION:=1.5.3}"
: "${APACHE_EXPORTER_VERSION:=1.1.3}"
: "${PHPFPM_EXPORTER_VERSION:=2.2.0}"
: "${KAFKA_EXPORTER_VERSION:=1.11.0}"
: "${ELASTICSEARCH_EXPORTER_VERSION:=1.11.0}"
: "${PROCESS_EXPORTER_VERSION:=0.8.7}"
: "${MEMCACHED_EXPORTER_VERSION:=0.18.0}"
: "${JMX_EXPORTER_VERSION:=1.7.0}"
: "${WINDOWS_EXPORTER_VERSION:=0.31.3}"
: "${CADVISOR_VERSION:=0.61.1}"

# --- Téléchargement ----------------------------------------------------------
: "${GITHUB_URL:=https://github.com}"
# yes = n'utilise que le répertoire packages/ (aucun accès Internet)
: "${OFFLINE:=no}"
# yes = vérifie le SHA256 quand le projet le publie ; strict = l'exige
: "${VERIFY_CHECKSUM:=yes}"

# --- Comptes système ---------------------------------------------------------
: "${PROMETHEUS_USER:=prometheus}"
: "${ALERTMANAGER_USER:=alertmanager}"
: "${EXPORTER_USER:=exporter}"

# --- Arborescence ------------------------------------------------------------
: "${BIN_DIR:=/usr/local/bin}"
: "${PROMETHEUS_CONF_DIR:=/etc/prometheus}"
: "${PROMETHEUS_DATA_DIR:=/var/lib/prometheus}"
: "${ALERTMANAGER_CONF_DIR:=/etc/alertmanager}"
: "${ALERTMANAGER_DATA_DIR:=/var/lib/alertmanager}"
: "${EXPORTERS_CONF_DIR:=/etc/prometheus-exporters}"
: "${JMX_DIR:=/opt/jmx_exporter}"
: "${SYSTEMD_DIR:=/etc/systemd/system}"
: "${LOG_DIR:=/var/log/prometheus-bundle}"
: "${BACKUP_DIR:=/var/backups/prometheus-bundle}"
: "${SAUVEGARDES_CONSERVEES:=14}"      # nombre d'archives de sauvegarde gardées

# --- Réseau ------------------------------------------------------------------
: "${PROMETHEUS_LISTEN_ADDRESS:=0.0.0.0}"
: "${PROMETHEUS_PORT:=9090}"
: "${ALERTMANAGER_LISTEN_ADDRESS:=0.0.0.0}"
: "${ALERTMANAGER_PORT:=9093}"
# Ouvrir automatiquement les ports dans firewalld/ufw : yes/no
: "${OPEN_FIREWALL:=no}"
# Adresse du blackbox_exporter utilisée pour les sondes HTTP/TCP/ICMP
: "${BLACKBOX_ADDRESS:=127.0.0.1:9115}"

# --- Prometheus --------------------------------------------------------------
: "${PROMETHEUS_RETENTION_TIME:=30d}"
: "${PROMETHEUS_RETENTION_SIZE:=0}"          # 0 = illimité, ex. 50GB
: "${PROMETHEUS_SCRAPE_INTERVAL:=30s}"
: "${PROMETHEUS_EVALUATION_INTERVAL:=30s}"
: "${PROMETHEUS_CLUSTER_LABEL:=production}"  # libellé "environnement" global

# --- Alertmanager ------------------------------------------------------------
: "${ALERTMANAGER_DATA_RETENTION:=120h}"
: "${ALERT_GROUP_WAIT:=30s}"        # délai avant le 1er envoi d'un groupe
: "${ALERT_GROUP_INTERVAL:=5m}"     # délai entre deux envois d'un groupe
: "${ALERT_REPEAT_INTERVAL:=4h}"    # rappel d'une alerte toujours active

# --- Grafana -----------------------------------------------------------------
: "${GRAFANA_PORT:=3000}"
: "${GRAFANA_ADMIN_PASSWORD:=}"      # vide = mot de passe généré
# URL de Prometheus vue par Grafana
: "${GRAFANA_PROMETHEUS_URL:=http://127.0.0.1:9090}"
# Machine Grafana distante (ex. admin@grafana01) ; vide = Grafana sur cette machine
: "${GRAFANA_HOTE_DISTANT:=}"

# --- Seuils des règles d'alerte ----------------------------------------------
#  Après modification : ./prometheus-bundle.sh 02 appliquer
# Serveurs (Linux / Windows)
: "${SEUIL_CPU_WARN:=85}"            # % CPU
: "${SEUIL_CPU_CRIT:=95}"
: "${SEUIL_MEMOIRE_WARN:=85}"        # % mémoire utilisée
: "${SEUIL_MEMOIRE_CRIT:=95}"
: "${SEUIL_DISQUE_WARN:=80}"         # % disque utilisé
: "${SEUIL_DISQUE_CRIT:=90}"
: "${SEUIL_CHARGE_PAR_CPU:=2}"       # charge moyenne 15 min / nombre de CPU
# Sites web / sondes
: "${SEUIL_HTTP_LATENCE_S:=2}"       # secondes
: "${SEUIL_CERT_JOURS_WARN:=21}"     # jours avant expiration du certificat
: "${SEUIL_CERT_JOURS_CRIT:=7}"
: "${SEUIL_PING_MS:=200}"
# Bases de données
: "${SEUIL_CONNEXIONS_PCT:=80}"      # % des connexions max (MySQL, PG, Redis, Mongo)
: "${SEUIL_REPLICATION_RETARD_S:=60}"
: "${SEUIL_MYSQL_REQUETES_LENTES:=10}"   # requêtes lentes / 5 min
: "${SEUIL_PG_TRANSACTION_LONGUE_S:=600}"
: "${SEUIL_REDIS_MEMOIRE_PCT:=90}"
# Middleware
: "${SEUIL_JVM_HEAP_PCT:=90}"
: "${SEUIL_JVM_GC_PCT:=20}"          # % du temps passé en GC
: "${SEUIL_JVM_THREADS:=1000}"
: "${SEUIL_HTTP_ERREURS_PCT:=5}"     # % de réponses 5xx
: "${SEUIL_KAFKA_LAG:=1000}"         # messages de retard d'un groupe consommateur
: "${SEUIL_RABBITMQ_MESSAGES:=10000}"
: "${SEUIL_NGINX_CONNEXIONS:=1000}"
: "${SEUIL_PHPFPM_FILE_ATTENTE:=10}"
: "${SEUIL_PROCESSUS_MEMOIRE_GO:=4}"
: "${SEUIL_CONTENEUR_MEMOIRE_PCT:=90}"

# =============================================================================
#  FIN DE LA CONFIGURATION — ne pas modifier en dessous sauf évolution du script
# =============================================================================

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "${SCRIPT_PATH}")"
SCRIPT_NAME="$(basename "${SCRIPT_PATH}")"
PACKAGES_DIR="${SCRIPT_DIR}/packages"
MARQUEUR="Géré par prometheus-bundle"
WORK_DIR=""

# --- Affichage ---------------------------------------------------------------
if [[ -t 1 ]]; then
    C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'
    C_C=$'\e[36m'; C_GRAS=$'\e[1m'; C_0=$'\e[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_C=""; C_GRAS=""; C_0=""
fi
_ts()       { date '+%H:%M:%S'; }
log_info()  { printf '%s %s[INFO]%s  %s\n' "$(_ts)" "${C_B}" "${C_0}" "$*"; }
log_ok()    { printf '%s %s[OK]%s    %s\n' "$(_ts)" "${C_G}" "${C_0}" "$*"; }
log_warn()  { printf '%s %s[WARN]%s  %s\n' "$(_ts)" "${C_Y}" "${C_0}" "$*"; }
log_error() { printf '%s %s[ERREUR]%s %s\n' "$(_ts)" "${C_R}" "${C_0}" "$*" >&2; }
titre()     { printf '\n%s==== %s ====%s\n' "${C_GRAS}" "$*" "${C_0}"; }
die()       { log_error "$*"; exit 1; }

init_log() {
    if mkdir -p "${LOG_DIR}" 2>/dev/null && [[ -w "${LOG_DIR}" ]]; then
        local f="${LOG_DIR}/${1}_$(date +%Y%m%d_%H%M%S).log"
        exec > >(tee -a "${f}") 2>&1
        log_info "Journal : ${f}"
    fi
}

require_root() { [[ ${EUID} -eq 0 ]] || die "À exécuter en tant que root (sudo)."; }
cmd_exists()   { command -v "$1" >/dev/null 2>&1; }

# Mode non interactif : ASSUME_YES=yes ou absence de terminal
interactif() { [[ -t 0 && "${ASSUME_YES:-no}" != "yes" ]]; }

confirm() {
    [[ "${ASSUME_YES:-no}" == "yes" ]] && return 0
    interactif || return 1
    local r; read -r -p "$1 [o/N] " r
    [[ "${r,,}" =~ ^(o|oui|y|yes)$ ]]
}

# demander <VARIABLE> "<question>" [défaut] [secret]
# Utilise la valeur déjà présente dans l'environnement si elle existe,
# sinon pose la question (ou prend le défaut en mode non interactif).
demander() {
    local var="$1" question="$2" defaut="${3:-}" secret="${4:-}" rep=""
    if [[ -n "${!var:-}" ]]; then return 0; fi
    if interactif; then
        if [[ "${secret}" == "secret" ]]; then
            read -r -s -p "${question} : " rep; echo
        elif [[ -n "${defaut}" ]]; then
            read -r -p "${question} [${defaut}] : " rep
        else
            read -r -p "${question} : " rep
        fi
    fi
    rep="${rep:-${defaut}}"
    [[ -n "${rep}" ]] || die "Valeur requise : ${var} (${question})"
    printf -v "${var}" '%s' "${rep}"
}

# --- Système -----------------------------------------------------------------
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;;
        armv7l) echo armv7 ;; ppc64le) echo ppc64le ;; s390x) echo s390x ;;
        *) echo unsupported ;;
    esac
}
detect_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        ( . /etc/os-release; echo "${ID:-inconnu} ${VERSION_ID:-?} ${ID_LIKE:-}" )
    else echo "inconnu"; fi
}
famille_os() {
    local os; os="$(detect_os)"
    case " ${os} " in
        *debian*|*ubuntu*) echo debian ;;
        *rhel*|*fedora*|*centos*|*rocky*|*almalinux*|*suse*) echo rhel ;;
        *) echo autre ;;
    esac
}
nom_hote() { hostname -s 2>/dev/null || hostname; }

download() {
    local url="$1" dest="$2"
    if cmd_exists curl; then curl -fsSL --retry 3 --connect-timeout 15 -o "${dest}" "${url}"
    elif cmd_exists wget; then wget -q --tries=3 --timeout=15 -O "${dest}" "${url}"
    else log_error "curl ou wget requis"; return 1; fi
}
url_ok() {
    if cmd_exists curl; then curl -fsL -r 0-0 --connect-timeout 10 -o /dev/null "$1"
    elif cmd_exists wget; then wget -q --spider --timeout=10 "$1"
    else return 1; fi
}
http_get() {
    if cmd_exists curl; then curl -fsS --max-time 10 "$1"
    else wget -qO- --timeout=10 "$1"; fi
}
http_post() {
    if cmd_exists curl; then curl -fsS --max-time 10 -X POST "$1" >/dev/null
    else wget -qO- --timeout=10 --post-data='' "$1" >/dev/null; fi
}
attendre_http() {
    local url="$1" t="${2:-30}" i
    for ((i = 0; i < t; i++)); do url_ok "${url}" && return 0; sleep 1; done
    return 1
}
port_utilise() {
    local p="$1"
    if cmd_exists ss; then ss -Htln "sport = :${p}" 2>/dev/null | grep -q .
    elif cmd_exists netstat; then netstat -tln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}\$"
    else (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null; fi
}
adresse_locale() { [[ "$1" == "0.0.0.0" || -z "$1" ]] && echo 127.0.0.1 || echo "$1"; }
prom_url() { echo "http://$(adresse_locale "${PROMETHEUS_LISTEN_ADDRESS}"):${PROMETHEUS_PORT}"; }
am_url()   { echo "http://$(adresse_locale "${ALERTMANAGER_LISTEN_ADDRESS}"):${ALERTMANAGER_PORT}"; }
prometheus_installe() { [[ -x "${BIN_DIR}/prometheus" && -f "${PROMETHEUS_CONF_DIR}/prometheus.yml" ]]; }
alertmanager_installe() { [[ -x "${BIN_DIR}/alertmanager" && -f "${ALERTMANAGER_CONF_DIR}/alertmanager.yml" ]]; }

workdir() {
    if [[ -z "${WORK_DIR}" ]]; then
        WORK_DIR="$(mktemp -d /tmp/prometheus-bundle.XXXXXX)"
        trap 'rm -rf "${WORK_DIR}"' EXIT
    fi
    echo "${WORK_DIR}"
}

# rendu : lit un gabarit sur l'entrée standard et remplace @@VARIABLE@@
rendu() {
    local c var
    c="$(cat)"
    while read -r var; do
        [[ -n "${var}" ]] || continue
        [[ -v "${var}" ]] || die "Variable de gabarit non définie : ${var}"
        c="${c//"@@${var}@@"/"${!var}"}"
    done < <(grep -o '@@[A-Z0-9_]\+@@' <<<"${c}" | tr -d '@' | sort -u)
    printf '%s\n' "${c}"
}

# ecrire_fichier <destination> <propriétaire:groupe> <mode>  (contenu sur stdin)
ecrire_fichier() {
    local dst="$1" owner="$2" mode="$3" tmp
    tmp="$(mktemp "${dst}.XXXXXX")" || die "Écriture impossible : ${dst}"
    cat > "${tmp}"
    if ! { chown "${owner}" "${tmp}" && chmod "${mode}" "${tmp}" && mv -f "${tmp}" "${dst}"; }; then
        rm -f "${tmp}"; die "Écriture impossible : ${dst} (propriétaire ${owner})"
    fi
}

creer_compte() {
    local user="$1" home="$2" nologin
    nologin="$(command -v nologin || echo /sbin/nologin)"
    getent group "${user}" >/dev/null || groupadd --system "${user}"
    if ! getent passwd "${user}" >/dev/null; then
        useradd --system --gid "${user}" --no-create-home --home-dir "${home}" \
                --shell "${nologin}" --comment "Compte de service ${user}" "${user}"
        log_ok "Compte système créé : ${user}"
    fi
}

ouvrir_port() {
    local port="$1" nom="$2"
    [[ "${OPEN_FIREWALL}" == "yes" ]] || return 0
    if cmd_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null && firewall-cmd --reload >/dev/null
        log_ok "firewalld : port ${port}/tcp ouvert (${nom})"
    elif cmd_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/tcp" comment "${nom}" >/dev/null
        log_ok "ufw : port ${port}/tcp ouvert (${nom})"
    fi
}
fermer_port() {
    local port="$1"
    if cmd_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        if firewall-cmd --permanent --query-port="${port}/tcp" >/dev/null 2>&1; then
            firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null && firewall-cmd --reload >/dev/null
            log_ok "firewalld : port ${port}/tcp fermé"
        fi
    elif cmd_exists ufw && ufw status 2>/dev/null | grep -q "^${port}/tcp"; then
        ufw --force delete allow "${port}/tcp" >/dev/null && log_ok "ufw : port ${port}/tcp fermé"
    fi
}

restaurer_selinux() {
    if cmd_exists restorecon && cmd_exists getenforce && [[ "$(getenforce)" != "Disabled" ]]; then
        restorecon -R "$@" 2>/dev/null || true
    fi
}

# --- Récupération d'une archive de release -----------------------------------
# recuperer <url> <nom_fichier> [url_sommes...]
# Cherche d'abord dans packages/, sinon télécharge. Vérifie le SHA256 si une
# des URL de sommes de contrôle répond. Affiche le chemin du fichier obtenu.
recuperer() {
    local url="$1" fichier="$2"; shift 2
    local dest; dest="$(workdir)/${fichier}"
    if [[ -f "${PACKAGES_DIR}/${fichier}" ]]; then
        cp "${PACKAGES_DIR}/${fichier}" "${dest}"
        log_info "Archive locale : packages/${fichier}" >&2
    elif [[ "${OFFLINE}" == "yes" ]]; then
        die "Mode hors-ligne : packages/${fichier} absent"
    else
        log_info "Téléchargement : ${url}" >&2
        download "${url}" "${dest}" || die "Téléchargement impossible : ${url}"
    fi
    if [[ "${VERIFY_CHECKSUM}" != "no" ]]; then
        local sums attendu="" s
        sums="$(workdir)/${fichier}.sums"
        for s in "$@"; do
            local local_sums="${PACKAGES_DIR}/$(basename "${s}")"
            if [[ -f "${local_sums}" ]] && cp "${local_sums}" "${sums}"; then :
            elif [[ "${OFFLINE}" != "yes" ]] && download "${s}" "${sums}" 2>/dev/null; then :
            else continue; fi
            attendu="$(awk -v f="${fichier}" '$2 == f || $2 == "*"f {print $1}' "${sums}")"
            [[ -n "${attendu}" ]] && break
        done
        if [[ -n "${attendu}" ]]; then
            [[ "$(sha256sum "${dest}" | awk '{print $1}')" == "${attendu}" ]] \
                || die "Somme SHA256 incorrecte : ${fichier}"
            log_ok "SHA256 vérifié : ${fichier}" >&2
        elif [[ "${VERIFY_CHECKSUM}" == "strict" ]]; then
            die "Aucune somme de contrôle publiée pour ${fichier} (VERIFY_CHECKSUM=strict)"
        else
            log_warn "Pas de somme de contrôle publiée pour ${fichier} : non vérifié" >&2
        fi
    fi
    echo "${dest}"
}

# extraire_binaire <archive_ou_binaire> <nom_binaire> <destination>
extraire_binaire() {
    local src="$1" bin="$2" dst="$3" x trouve
    if tar -tzf "${src}" >/dev/null 2>&1; then
        x="$(workdir)/x_${bin}"; mkdir -p "${x}"
        tar -xzf "${src}" -C "${x}" || die "Extraction impossible : ${src}"
        trouve="$(find "${x}" -type f -name "${bin}" | head -n1)"
        [[ -n "${trouve}" ]] || die "Binaire ${bin} introuvable dans l'archive"
    else
        trouve="${src}"
    fi
    install -m 0755 -o root -g root "${trouve}" "${dst}"
}

# Réécrit une valeur par défaut dans la section CONFIGURATION du script
definir_parametre() {
    local var="$1" val="$2"
    [[ "${var}" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "Nom de variable invalide : ${var}"
    grep -q "^: \"\${${var}:=" "${SCRIPT_PATH}" || die "Paramètre inconnu : ${var} (voir : 02 afficher)"
    [[ "${val}" != *$'\n'* && "${val}" != *'"'* && "${val}" != *'`'* && "${val}" != *'$'* ]] \
        || die "Valeur refusée (caractères interdits : \" \` \$ ou retour ligne)"
    local esc="${val//\\/\\\\}"; esc="${esc//&/\\&}"; esc="${esc//|/\\|}"
    sed -i "s|^: \"\${${var}:=[^}]*}\"|: \"\${${var}:=${esc}}\"|" "${SCRIPT_PATH}" \
        || die "Mise à jour du script impossible"
    printf -v "${var}" '%s' "${val}"
    log_ok "${var} = ${val} (enregistré dans ${SCRIPT_NAME})"
}

# =============================================================================
#  CATALOGUE DES APPLICATIONS SUPERVISABLES
# =============================================================================
APPLICATIONS=(linux windows http tcp icmp mysql postgresql redis mongodb memcached
              elasticsearch nginx apache phpfpm haproxy rabbitmq kafka jvm
              springboot process docker application)

gh_url() { echo "${GITHUB_URL}/$1/releases/download/$2/$3"; }

# catalogue <application> : renseigne les variables APP_*
#   APP_NOM        libellé
#   APP_CATEGORIE  famille (Système, Web, Base de données...)
#   APP_PORT       port par défaut de la cible
#   APP_AGENT      exporter | jmx | natif | externe (agent hors Linux)
#   APP_BIN        nom du binaire / de l'unité systemd de l'agent
#   APP_URL        URL de l'archive de l'agent
#   APP_SUMS       URL(s) des sommes de contrôle
#   APP_REGLES     fichier de règles associé
catalogue() {
    local a; a="$(detect_arch)"
    APP_PORT=""; APP_AGENT="exporter"; APP_BIN=""; APP_URL=""; APP_SUMS=""
    APP_REGLES="$1"; APP_METRICS_PATH="/metrics"
    _promstyle() { # <repo> <binaire> <version> [fichier_sommes]
        APP_BIN="$2"
        APP_URL="$(gh_url "$1" "v$3" "$2-$3.linux-${a}.tar.gz")"
        APP_SUMS="$(gh_url "$1" "v$3" "${4:-sha256sums.txt}")"
    }
    case "$1" in
    linux)
        APP_NOM="Serveur Linux (CPU, mémoire, disques, réseau, services systemd)"
        APP_CATEGORIE="Système"; APP_PORT=9100
        _promstyle prometheus/node_exporter node_exporter "${NODE_EXPORTER_VERSION}" ;;
    windows)
        APP_NOM="Serveur Windows (CPU, mémoire, disques, services)"
        APP_CATEGORIE="Système"; APP_PORT=9182; APP_AGENT="externe" ;;
    http)
        APP_NOM="Site / API web : disponibilité, code HTTP, temps de réponse, certificat TLS"
        APP_CATEGORIE="Disponibilité"; APP_PORT=""; APP_REGLES="sondes"
        _promstyle prometheus/blackbox_exporter blackbox_exporter "${BLACKBOX_EXPORTER_VERSION}" ;;
    tcp)
        APP_NOM="Port TCP (base, SMTP, LDAP...) : ouverture du port"
        APP_CATEGORIE="Disponibilité"; APP_PORT=""; APP_REGLES="sondes"
        _promstyle prometheus/blackbox_exporter blackbox_exporter "${BLACKBOX_EXPORTER_VERSION}" ;;
    icmp)
        APP_NOM="Équipement réseau / hôte : ping (ICMP)"
        APP_CATEGORIE="Disponibilité"; APP_PORT=""; APP_REGLES="sondes"
        _promstyle prometheus/blackbox_exporter blackbox_exporter "${BLACKBOX_EXPORTER_VERSION}" ;;
    mysql)
        APP_NOM="MySQL / MariaDB (connexions, réplication, requêtes lentes, InnoDB)"
        APP_CATEGORIE="Base de données"; APP_PORT=9104
        _promstyle prometheus/mysqld_exporter mysqld_exporter "${MYSQLD_EXPORTER_VERSION}" ;;
    postgresql)
        APP_NOM="PostgreSQL (connexions, réplication, verrous, transactions longues)"
        APP_CATEGORIE="Base de données"; APP_PORT=9187
        _promstyle prometheus-community/postgres_exporter postgres_exporter "${POSTGRES_EXPORTER_VERSION}" ;;
    redis)
        APP_NOM="Redis (mémoire, clients, évictions, persistance, réplication)"
        APP_CATEGORIE="Base de données"; APP_PORT=9121; APP_BIN="redis_exporter"
        APP_URL="$(gh_url oliver006/redis_exporter "v${REDIS_EXPORTER_VERSION}" "redis_exporter-v${REDIS_EXPORTER_VERSION}.linux-${a}.tar.gz")"
        APP_SUMS="$(gh_url oliver006/redis_exporter "v${REDIS_EXPORTER_VERSION}" sha256sums.txt)" ;;
    mongodb)
        APP_NOM="MongoDB (connexions, replica set, assertions)"
        APP_CATEGORIE="Base de données"; APP_PORT=9216
        _promstyle percona/mongodb_exporter mongodb_exporter "${MONGODB_EXPORTER_VERSION}" ;;
    memcached)
        APP_NOM="Memcached (mémoire, évictions, connexions)"
        APP_CATEGORIE="Base de données"; APP_PORT=9150
        _promstyle prometheus/memcached_exporter memcached_exporter "${MEMCACHED_EXPORTER_VERSION}" ;;
    elasticsearch)
        APP_NOM="Elasticsearch / OpenSearch (santé du cluster, heap, disque, shards)"
        APP_CATEGORIE="Base de données"; APP_PORT=9114
        _promstyle prometheus-community/elasticsearch_exporter elasticsearch_exporter "${ELASTICSEARCH_EXPORTER_VERSION}" ;;
    nginx)
        APP_NOM="Nginx (disponibilité, connexions actives et rejetées)"
        APP_CATEGORIE="Serveur web"; APP_PORT=9113; APP_BIN="nginx-prometheus-exporter"
        APP_URL="$(gh_url nginx/nginx-prometheus-exporter "v${NGINX_EXPORTER_VERSION}" "nginx-prometheus-exporter_${NGINX_EXPORTER_VERSION}_linux_${a}.tar.gz")"
        APP_SUMS="$(gh_url nginx/nginx-prometheus-exporter "v${NGINX_EXPORTER_VERSION}" "nginx-prometheus-exporter_${NGINX_EXPORTER_VERSION}_checksums.txt")" ;;
    apache)
        APP_NOM="Apache httpd (disponibilité, workers, redémarrages)"
        APP_CATEGORIE="Serveur web"; APP_PORT=9117
        _promstyle lusitaniae/apache_exporter apache_exporter "${APACHE_EXPORTER_VERSION}" ;;
    phpfpm)
        APP_NOM="PHP-FPM (pool saturé, file d'attente, requêtes lentes)"
        APP_CATEGORIE="Serveur web"; APP_PORT=9253; APP_BIN="php-fpm_exporter"
        APP_URL="$(gh_url hipages/php-fpm_exporter "v${PHPFPM_EXPORTER_VERSION}" "php-fpm_exporter_${PHPFPM_EXPORTER_VERSION}_linux_${a}.tar.gz")"
        APP_SUMS="$(gh_url hipages/php-fpm_exporter "v${PHPFPM_EXPORTER_VERSION}" "php-fpm_exporter_${PHPFPM_EXPORTER_VERSION}_checksums.txt") $(gh_url hipages/php-fpm_exporter "v${PHPFPM_EXPORTER_VERSION}" checksums.txt)" ;;
    haproxy)
        APP_NOM="HAProxy (backends sans serveur, erreurs 5xx, sessions) — exporteur intégré"
        APP_CATEGORIE="Serveur web"; APP_PORT=8405; APP_AGENT="natif" ;;
    rabbitmq)
        APP_NOM="RabbitMQ (alarmes mémoire/disque, files, consommateurs) — plugin intégré"
        APP_CATEGORIE="Messagerie"; APP_PORT=15692; APP_AGENT="natif" ;;
    kafka)
        APP_NOM="Kafka (brokers, partitions, retard des consommateurs)"
        APP_CATEGORIE="Messagerie"; APP_PORT=9308
        _promstyle danielqsj/kafka_exporter kafka_exporter "${KAFKA_EXPORTER_VERSION}" ;;
    jvm)
        APP_NOM="Application Java : Tomcat, JBoss/WildFly, Jetty, ActiveMQ... (agent JMX)"
        APP_CATEGORIE="Application"; APP_PORT=9404; APP_AGENT="jmx"; APP_BIN="jmx_prometheus_javaagent"
        APP_URL="$(gh_url prometheus/jmx_exporter "${JMX_EXPORTER_VERSION}" "jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar")"
        APP_SUMS="${APP_URL}.sha256" ;;
    springboot)
        APP_NOM="Application Spring Boot (Actuator/Micrometer : JVM, erreurs HTTP, latence)"
        APP_CATEGORIE="Application"; APP_PORT=8080; APP_AGENT="natif"; APP_REGLES="jvm"
        APP_METRICS_PATH="/actuator/prometheus" ;;
    process)
        APP_NOM="Processus applicatifs (présence, mémoire, descripteurs de fichiers)"
        APP_CATEGORIE="Application"; APP_PORT=9256
        _promstyle ncabatoff/process-exporter process-exporter "${PROCESS_EXPORTER_VERSION}" checksums.txt ;;
    docker)
        APP_NOM="Conteneurs Docker via cAdvisor (CPU, mémoire, OOM, disparition)"
        APP_CATEGORIE="Application"; APP_PORT=8080; APP_AGENT="externe" ;;
    application)
        APP_NOM="Application instrumentée (endpoint /metrics : Go, Python, Node.js, .NET...)"
        APP_CATEGORIE="Application"; APP_PORT=""; APP_AGENT="natif" ;;
    *) return 1 ;;
    esac
    return 0
}

app_valide() { catalogue "$1" 2>/dev/null; }

afficher_catalogue() {
    titre "Catalogue des applications supervisables"
    local app cat_prec=""
    for app in "${APPLICATIONS[@]}"; do
        catalogue "${app}"
        if [[ "${APP_CATEGORIE}" != "${cat_prec}" ]]; then
            printf '\n %s%s%s\n' "${C_GRAS}" "${APP_CATEGORIE}" "${C_0}"
            cat_prec="${APP_CATEGORIE}"
        fi
        local agent
        case "${APP_AGENT}" in
            exporter) agent="agent ${APP_BIN}" ;;
            jmx)      agent="agent Java JMX" ;;
            natif)    agent="sans agent (exposition native)" ;;
            externe)  agent="agent à installer hors Linux" ;;
        esac
        [[ "${app}" =~ ^(http|tcp|icmp)$ ]] && agent="sonde blackbox_exporter"
        printf '   %s%-14s%s %s\n   %-14s %s%s%s\n' "${C_C}" "${app}" "${C_0}" "${APP_NOM}" "" "${C_Y}" "${agent}${APP_PORT:+ — port ${APP_PORT}}" "${C_0}"
    done
    echo
}

# =============================================================================
#  RÈGLES D'ALERTE PAR APPLICATION
# -----------------------------------------------------------------------------
#  Sévérités : critical = intervention immédiate, warning = à traiter dans la
#  journée, info = information. Les seuils @@...@@ viennent de la CONFIGURATION.
# =============================================================================
REGLES_FICHIERS=(base linux windows sondes mysql postgresql redis mongodb memcached
                 elasticsearch nginx apache phpfpm haproxy rabbitmq kafka jvm
                 process docker application)

# Filtre des systèmes de fichiers pris en compte pour les alertes disque
FS_FILTRE='fstype!~"tmpfs|ramfs|devtmpfs|overlay|squashfs|nsfs|fuse.*|iso9660",mountpoint!~"/run.*|/boot/efi"'

regles_contenu() {
    case "$1" in
# -----------------------------------------------------------------------------
base) cat <<'EOF' ;;
groups:
  - name: supervision
    rules:
      - alert: CibleInjoignable
        expr: 'up == 0'
        for: 2m
        labels: {severity: critical, categorie: supervision}
        annotations:
          summary: "{{ $labels.job }} injoignable sur {{ $labels.instance }}"
          description: "Prometheus ne parvient plus à collecter {{ $labels.instance }} (job {{ $labels.job }}) depuis 2 minutes : service, agent ou réseau en panne."
      - alert: MajoriteCiblesInjoignables
        expr: '(count by (job) (up == 0) / count by (job) (up)) > 0.5 and count by (job) (up) > 1'
        for: 5m
        labels: {severity: critical, categorie: supervision}
        annotations:
          summary: "Plus de la moitié des cibles du job {{ $labels.job }} sont injoignables"
          description: "{{ $value | humanizePercentage }} des cibles du job {{ $labels.job }} ne répondent plus : incident réseau ou panne générale probable."
      - alert: PrometheusConfigurationInvalide
        expr: 'prometheus_config_last_reload_successful == 0'
        for: 5m
        labels: {severity: warning, categorie: supervision}
        annotations:
          summary: "Échec du rechargement de la configuration Prometheus"
          description: "La dernière configuration n'a pas été chargée sur {{ $labels.instance }}. Vérifier avec : promtool check config."
      - alert: PrometheusAlertmanagerDeconnecte
        expr: 'prometheus_notifications_alertmanagers_discovered < 1'
        for: 5m
        labels: {severity: critical, categorie: supervision}
        annotations:
          summary: "Prometheus n'est connecté à aucun Alertmanager"
          description: "Aucune alerte ne peut être envoyée depuis {{ $labels.instance }}."
      - alert: PrometheusEchecEnvoiAlertes
        expr: 'rate(prometheus_notifications_errors_total[5m]) > 0'
        for: 5m
        labels: {severity: critical, categorie: supervision}
        annotations:
          summary: "Prometheus n'arrive pas à transmettre les alertes"
          description: "Erreurs d'envoi vers Alertmanager {{ $labels.alertmanager }}."
      - alert: PrometheusEchecEvaluationRegles
        expr: 'increase(prometheus_rule_evaluation_failures_total[10m]) > 0'
        for: 0m
        labels: {severity: warning, categorie: supervision}
        annotations:
          summary: "Des règles d'alerte échouent à l'évaluation"
          description: "Groupe {{ $labels.rule_group }} : {{ $value | humanize }} échecs en 10 min."
      - alert: PrometheusEchecCompactionTSDB
        expr: 'increase(prometheus_tsdb_compactions_failed_total[3h]) > 0'
        labels: {severity: warning, categorie: supervision}
        annotations:
          summary: "Échec de compaction de la base Prometheus"
          description: "La base de données de {{ $labels.instance }} rencontre des erreurs : vérifier l'espace disque."
      - alert: AlertmanagerConfigurationInvalide
        expr: 'alertmanager_config_last_reload_successful == 0'
        for: 5m
        labels: {severity: warning, categorie: supervision}
        annotations:
          summary: "Échec du rechargement de la configuration Alertmanager"
          description: "Vérifier avec : amtool check-config."
      - alert: AlertmanagerEchecNotifications
        expr: 'rate(alertmanager_notifications_failed_total[5m]) > 0'
        for: 5m
        labels: {severity: critical, categorie: supervision}
        annotations:
          summary: "Le canal {{ $labels.integration }} n'envoie plus les alertes"
          description: "Alertmanager échoue à notifier via {{ $labels.integration }} : jeton expiré, URL modifiée ou service tiers indisponible."
  - name: watchdog
    rules:
      - alert: Watchdog
        expr: 'vector(1)'
        labels: {severity: none, categorie: supervision}
        annotations:
          summary: "Alerte de contrôle toujours active (chaîne d'alerte opérationnelle)"
          description: "Cette alerte est volontairement toujours active. Elle n'est envoyée à aucun canal."
EOF
# -----------------------------------------------------------------------------
linux) cat <<'EOF' ;;
groups:
  - name: linux
    rules:
      - alert: HoteCPUSature
        expr: '100 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100 > @@SEUIL_CPU_WARN@@'
        for: 15m
        labels: {severity: warning, categorie: systeme}
        annotations:
          summary: "CPU à {{ $value | printf \"%.0f\" }} % sur {{ $labels.instance }}"
          description: "Utilisation CPU supérieure à @@SEUIL_CPU_WARN@@ % depuis 15 minutes."
      - alert: HoteCPUCritique
        expr: '100 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100 > @@SEUIL_CPU_CRIT@@'
        for: 10m
        labels: {severity: critical, categorie: systeme}
        annotations:
          summary: "CPU saturé ({{ $value | printf \"%.0f\" }} %) sur {{ $labels.instance }}"
          description: "Utilisation CPU supérieure à @@SEUIL_CPU_CRIT@@ % depuis 10 minutes : les applications sont ralenties."
      - alert: HoteChargeElevee
        expr: 'node_load15 / on (instance) count by (instance) (node_cpu_seconds_total{mode="idle"}) > @@SEUIL_CHARGE_PAR_CPU@@'
        for: 15m
        labels: {severity: warning, categorie: systeme}
        annotations:
          summary: "Charge système élevée sur {{ $labels.instance }}"
          description: "Charge moyenne 15 min = {{ $value | printf \"%.1f\" }} par CPU (seuil @@SEUIL_CHARGE_PAR_CPU@@) : processus en attente CPU ou disque."
      - alert: HoteIOWaitEleve
        expr: 'avg by (instance) (rate(node_cpu_seconds_total{mode="iowait"}[5m])) * 100 > 20'
        for: 15m
        labels: {severity: warning, categorie: systeme}
        annotations:
          summary: "Attente disque (iowait) à {{ $value | printf \"%.0f\" }} % sur {{ $labels.instance }}"
          description: "Le stockage est trop lent pour la charge demandée."
      - alert: HoteMemoireSaturee
        expr: '(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > @@SEUIL_MEMOIRE_WARN@@'
        for: 10m
        labels: {severity: warning, categorie: systeme}
        annotations:
          summary: "Mémoire utilisée à {{ $value | printf \"%.0f\" }} % sur {{ $labels.instance }}"
          description: "Mémoire disponible faible (seuil @@SEUIL_MEMOIRE_WARN@@ %)."
      - alert: HoteMemoireCritique
        expr: '(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > @@SEUIL_MEMOIRE_CRIT@@'
        for: 5m
        labels: {severity: critical, categorie: systeme}
        annotations:
          summary: "Mémoire épuisée ({{ $value | printf \"%.0f\" }} %) sur {{ $labels.instance }}"
          description: "Risque imminent d'arrêt de processus par le noyau (OOM killer)."
      - alert: HoteProcessusTueOOM
        expr: 'increase(node_vmstat_oom_kill[15m]) > 0'
        labels: {severity: warning, categorie: systeme}
        annotations:
          summary: "Processus tué par manque de mémoire sur {{ $labels.instance }}"
          description: "Le noyau a tué {{ $value | humanize }} processus (OOM killer) en 15 min. Voir : journalctl -k | grep -i oom."
      - alert: HoteSwapIntensif
        expr: '(1 - node_memory_SwapFree_bytes / node_memory_SwapTotal_bytes) * 100 > 80 and node_memory_SwapTotal_bytes > 0'
        for: 15m
        labels: {severity: warning, categorie: systeme}
        annotations:
          summary: "Swap utilisé à {{ $value | printf \"%.0f\" }} % sur {{ $labels.instance }}"
          description: "Le serveur manque durablement de mémoire vive."
      - alert: HoteDisquePlein
        expr: '(1 - node_filesystem_avail_bytes{@@FS_FILTRE@@} / node_filesystem_size_bytes{@@FS_FILTRE@@}) * 100 > @@SEUIL_DISQUE_WARN@@'
        for: 10m
        labels: {severity: warning, categorie: systeme}
        annotations:
          summary: "Disque {{ $labels.mountpoint }} rempli à {{ $value | printf \"%.0f\" }} % sur {{ $labels.instance }}"
          description: "Seuil d'avertissement @@SEUIL_DISQUE_WARN@@ % dépassé : prévoir un nettoyage ou une extension."
      - alert: HoteDisqueCritique
        expr: '(1 - node_filesystem_avail_bytes{@@FS_FILTRE@@} / node_filesystem_size_bytes{@@FS_FILTRE@@}) * 100 > @@SEUIL_DISQUE_CRIT@@'
        for: 5m
        labels: {severity: critical, categorie: systeme}
        annotations:
          summary: "Disque {{ $labels.mountpoint }} presque plein ({{ $value | printf \"%.0f\" }} %) sur {{ $labels.instance }}"
          description: "Au-delà de @@SEUIL_DISQUE_CRIT@@ % : risque d'arrêt des applications et bases de données."
      - alert: HoteDisquePleinSous24h
        expr: 'predict_linear(node_filesystem_avail_bytes{@@FS_FILTRE@@}[6h], 24 * 3600) < 0 and node_filesystem_avail_bytes{@@FS_FILTRE@@} / node_filesystem_size_bytes{@@FS_FILTRE@@} < 0.4'
        for: 30m
        labels: {severity: warning, categorie: systeme}
        annotations:
          summary: "Le disque {{ $labels.mountpoint }} sera plein dans moins de 24 h sur {{ $labels.instance }}"
          description: "Projection basée sur la tendance des 6 dernières heures."
      - alert: HoteInodesEpuises
        expr: 'node_filesystem_files_free{@@FS_FILTRE@@} / node_filesystem_files{@@FS_FILTRE@@} * 100 < 10 and node_filesystem_files{@@FS_FILTRE@@} > 0'
        for: 10m
        labels: {severity: warning, categorie: systeme}
        annotations:
          summary: "Inodes presque épuisés sur {{ $labels.mountpoint }} ({{ $labels.instance }})"
          description: "Il reste {{ $value | printf \"%.0f\" }} % d'inodes : trop de petits fichiers (sessions, cache, logs)."
      - alert: HoteDisqueLectureSeule
        expr: 'node_filesystem_readonly{@@FS_FILTRE@@} == 1'
        for: 2m
        labels: {severity: critical, categorie: systeme}
        annotations:
          summary: "Système de fichiers {{ $labels.mountpoint }} passé en lecture seule sur {{ $labels.instance }}"
          description: "Erreur disque probable : vérifier dmesg et l'état du stockage."
      - alert: HoteDisqueSature
        expr: 'rate(node_disk_io_time_seconds_total[5m]) > 0.9'
        for: 15m
        labels: {severity: warning, categorie: systeme}
        annotations:
          summary: "Disque {{ $labels.device }} occupé à plus de 90 % sur {{ $labels.instance }}"
          description: "Le périphérique est saturé en entrées/sorties."
      - alert: HoteServiceSystemdEnEchec
        expr: 'node_systemd_unit_state{state="failed"} == 1'
        for: 5m
        labels: {severity: warning, categorie: systeme}
        annotations:
          summary: "Service {{ $labels.name }} en échec sur {{ $labels.instance }}"
          description: "Voir : systemctl status {{ $labels.name }} ; journalctl -u {{ $labels.name }}."
      - alert: HoteRedemarre
        expr: 'node_time_seconds - node_boot_time_seconds < 600'
        labels: {severity: info, categorie: systeme}
        annotations:
          summary: "{{ $labels.instance }} vient de redémarrer"
          description: "Le serveur a démarré il y a moins de 10 minutes."
      - alert: HoteHorlogeDesynchronisee
        expr: 'abs(node_timex_offset_seconds) > 0.5 or node_timex_sync_status == 0'
        for: 15m
        labels: {severity: warning, categorie: systeme}
        annotations:
          summary: "Horloge désynchronisée sur {{ $labels.instance }}"
          description: "Vérifier chrony/ntpd : une horloge fausse perturbe certificats, logs et clusters."
      - alert: HoteErreursReseau
        expr: 'rate(node_network_receive_errs_total[5m]) + rate(node_network_transmit_errs_total[5m]) > 1'
        for: 10m
        labels: {severity: warning, categorie: systeme}
        annotations:
          summary: "Erreurs réseau sur {{ $labels.device }} ({{ $labels.instance }})"
          description: "{{ $value | printf \"%.1f\" }} erreurs/s : câble, carte ou pilote défaillant."
      - alert: HoteInterfaceReseauDown
        expr: 'node_network_up{device!~"lo|veth.*|docker.*|br-.*|virbr.*|cali.*|flannel.*|cni.*|tun.*|tap.*"} == 0 and max_over_time(node_network_up[1h]) == 1'
        for: 5m
        labels: {severity: warning, categorie: systeme}
        annotations:
          summary: "Interface réseau {{ $labels.device }} inactive sur {{ $labels.instance }}"
          description: "L'interface était active dans la dernière heure et ne transmet plus."
      - alert: HoteTableConntrackPleine
        expr: 'node_nf_conntrack_entries / node_nf_conntrack_entries_limit > 0.8'
        for: 5m
        labels: {severity: warning, categorie: systeme}
        annotations:
          summary: "Table conntrack remplie à {{ $value | humanizePercentage }} sur {{ $labels.instance }}"
          description: "Au-delà de 100 % les nouvelles connexions sont rejetées."
      - alert: HoteDescripteursFichiers
        expr: 'node_filefd_allocated / node_filefd_maximum > 0.8'
        for: 10m
        labels: {severity: warning, categorie: systeme}
        annotations:
          summary: "Descripteurs de fichiers à {{ $value | humanizePercentage }} sur {{ $labels.instance }}"
          description: "Risque d'erreurs 'Too many open files'."
EOF
# -----------------------------------------------------------------------------
windows) cat <<'EOF' ;;
groups:
  - name: windows
    rules:
      - alert: WindowsCPUSature
        expr: '100 - avg by (instance) (rate(windows_cpu_time_total{mode="idle"}[5m])) * 100 > @@SEUIL_CPU_WARN@@'
        for: 15m
        labels: {severity: warning, categorie: systeme}
        annotations:
          summary: "CPU à {{ $value | printf \"%.0f\" }} % sur {{ $labels.instance }} (Windows)"
          description: "Utilisation CPU supérieure à @@SEUIL_CPU_WARN@@ % depuis 15 minutes."
      - alert: WindowsCPUCritique
        expr: '100 - avg by (instance) (rate(windows_cpu_time_total{mode="idle"}[5m])) * 100 > @@SEUIL_CPU_CRIT@@'
        for: 10m
        labels: {severity: critical, categorie: systeme}
        annotations:
          summary: "CPU saturé sur {{ $labels.instance }} (Windows)"
          description: "Utilisation CPU supérieure à @@SEUIL_CPU_CRIT@@ % depuis 10 minutes."
      - alert: WindowsMemoireSaturee
        expr: '100 - windows_memory_available_bytes / windows_memory_physical_total_bytes * 100 > @@SEUIL_MEMOIRE_WARN@@'
        for: 10m
        labels: {severity: warning, categorie: systeme}
        annotations:
          summary: "Mémoire utilisée à {{ $value | printf \"%.0f\" }} % sur {{ $labels.instance }} (Windows)"
          description: "Seuil @@SEUIL_MEMOIRE_WARN@@ % dépassé."
      - alert: WindowsDisquePlein
        expr: '100 - windows_logical_disk_free_bytes{volume!~"HarddiskVolume.*"} / windows_logical_disk_size_bytes{volume!~"HarddiskVolume.*"} * 100 > @@SEUIL_DISQUE_WARN@@'
        for: 10m
        labels: {severity: warning, categorie: systeme}
        annotations:
          summary: "Disque {{ $labels.volume }} rempli à {{ $value | printf \"%.0f\" }} % sur {{ $labels.instance }}"
          description: "Seuil @@SEUIL_DISQUE_WARN@@ % dépassé."
      - alert: WindowsDisqueCritique
        expr: '100 - windows_logical_disk_free_bytes{volume!~"HarddiskVolume.*"} / windows_logical_disk_size_bytes{volume!~"HarddiskVolume.*"} * 100 > @@SEUIL_DISQUE_CRIT@@'
        for: 5m
        labels: {severity: critical, categorie: systeme}
        annotations:
          summary: "Disque {{ $labels.volume }} presque plein sur {{ $labels.instance }}"
          description: "Au-delà de @@SEUIL_DISQUE_CRIT@@ %."
      - alert: WindowsServiceAutomatiqueArrete
        expr: 'windows_service_state{state="stopped"} == 1 and on (instance, name) windows_service_start_mode{start_mode="auto"} == 1'
        for: 5m
        labels: {severity: warning, categorie: systeme}
        annotations:
          summary: "Service Windows {{ $labels.name }} arrêté sur {{ $labels.instance }}"
          description: "Service en démarrage automatique mais arrêté."
EOF
# -----------------------------------------------------------------------------
sondes) cat <<'EOF' ;;
groups:
  - name: sondes
    rules:
      - alert: SiteInaccessible
        expr: 'probe_success{job="http"} == 0'
        for: 2m
        labels: {severity: critical, categorie: disponibilite}
        annotations:
          summary: "Site {{ $labels.instance }} inaccessible"
          description: "La sonde HTTP échoue depuis 2 minutes : site arrêté, erreur HTTP, DNS ou certificat invalide."
      - alert: SiteErreurServeur
        expr: 'probe_http_status_code{job="http"} >= 500'
        for: 2m
        labels: {severity: critical, categorie: disponibilite}
        annotations:
          summary: "Le site {{ $labels.instance }} répond en erreur {{ $value }}"
          description: "Erreur côté serveur applicatif."
      - alert: SiteLent
        expr: 'avg_over_time(probe_duration_seconds{job="http"}[5m]) > @@SEUIL_HTTP_LATENCE_S@@'
        for: 10m
        labels: {severity: warning, categorie: disponibilite}
        annotations:
          summary: "Le site {{ $labels.instance }} répond en {{ $value | printf \"%.1f\" }} s"
          description: "Temps de réponse moyen supérieur à @@SEUIL_HTTP_LATENCE_S@@ s depuis 10 minutes."
      - alert: CertificatExpireBientot
        expr: '(probe_ssl_earliest_cert_expiry - time()) / 86400 < @@SEUIL_CERT_JOURS_WARN@@'
        for: 1h
        labels: {severity: warning, categorie: disponibilite}
        annotations:
          summary: "Certificat de {{ $labels.instance }} expire dans {{ $value | printf \"%.0f\" }} jours"
          description: "Renouveler le certificat TLS (seuil @@SEUIL_CERT_JOURS_WARN@@ jours)."
      - alert: CertificatExpireImminent
        expr: '(probe_ssl_earliest_cert_expiry - time()) / 86400 < @@SEUIL_CERT_JOURS_CRIT@@'
        for: 10m
        labels: {severity: critical, categorie: disponibilite}
        annotations:
          summary: "Certificat de {{ $labels.instance }} expire dans {{ $value | printf \"%.0f\" }} jours"
          description: "Expiration imminente ou dépassée : les clients vont refuser la connexion."
      - alert: PortTCPFerme
        expr: 'probe_success{job="tcp"} == 0'
        for: 2m
        labels: {severity: critical, categorie: disponibilite}
        annotations:
          summary: "Port {{ $labels.instance }} injoignable"
          description: "La connexion TCP échoue depuis 2 minutes."
      - alert: HoteNeRepondPasAuPing
        expr: 'probe_success{job="icmp"} == 0'
        for: 2m
        labels: {severity: critical, categorie: disponibilite}
        annotations:
          summary: "{{ $labels.instance }} ne répond plus au ping"
          description: "Équipement éteint ou réseau coupé."
      - alert: PingLent
        expr: 'avg_over_time(probe_icmp_duration_seconds{job="icmp",phase="rtt"}[5m]) * 1000 > @@SEUIL_PING_MS@@'
        for: 10m
        labels: {severity: warning, categorie: disponibilite}
        annotations:
          summary: "Latence réseau de {{ $value | printf \"%.0f\" }} ms vers {{ $labels.instance }}"
          description: "Seuil @@SEUIL_PING_MS@@ ms dépassé."
EOF
# -----------------------------------------------------------------------------
mysql) cat <<'EOF' ;;
groups:
  - name: mysql
    rules:
      - alert: MySQLArrete
        expr: 'mysql_up == 0'
        for: 1m
        labels: {severity: critical, categorie: base-de-donnees}
        annotations:
          summary: "MySQL/MariaDB arrêté sur {{ $labels.instance }}"
          description: "L'agent n'arrive plus à se connecter à la base."
      - alert: MySQLConnexionsSaturees
        expr: 'mysql_global_status_threads_connected / mysql_global_variables_max_connections * 100 > @@SEUIL_CONNEXIONS_PCT@@'
        for: 5m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "MySQL : {{ $value | printf \"%.0f\" }} % des connexions utilisées sur {{ $labels.instance }}"
          description: "Au-delà de max_connections les clients sont refusés."
      - alert: MySQLConnexionsRefusees
        expr: 'increase(mysql_global_status_connection_errors_total{error="max_connections"}[5m]) > 0'
        labels: {severity: critical, categorie: base-de-donnees}
        annotations:
          summary: "MySQL refuse des connexions (max_connections atteint) sur {{ $labels.instance }}"
          description: "{{ $value | humanize }} connexions refusées en 5 min."
      - alert: MySQLThreadsActifsEleves
        expr: 'mysql_global_status_threads_running > 50'
        for: 10m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "MySQL : {{ $value }} requêtes simultanées sur {{ $labels.instance }}"
          description: "Plus de 50 requêtes exécutées simultanément : base surchargée ou verrous."
      - alert: MySQLRequetesLentes
        expr: 'increase(mysql_global_status_slow_queries[5m]) > @@SEUIL_MYSQL_REQUETES_LENTES@@'
        for: 5m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "MySQL : {{ $value | printf \"%.0f\" }} requêtes lentes en 5 min sur {{ $labels.instance }}"
          description: "Analyser le slow query log (index manquants, requêtes coûteuses)."
      - alert: MySQLReplicationIOArretee
        expr: 'mysql_slave_status_slave_io_running == 0'
        for: 1m
        labels: {severity: critical, categorie: base-de-donnees}
        annotations:
          summary: "Réplication MySQL (thread IO) arrêtée sur {{ $labels.instance }}"
          description: "Le réplica ne reçoit plus les journaux du primaire. Voir : SHOW REPLICA STATUS."
      - alert: MySQLReplicationSQLArretee
        expr: 'mysql_slave_status_slave_sql_running == 0'
        for: 1m
        labels: {severity: critical, categorie: base-de-donnees}
        annotations:
          summary: "Réplication MySQL (thread SQL) arrêtée sur {{ $labels.instance }}"
          description: "Une erreur bloque l'application des transactions. Voir : SHOW REPLICA STATUS."
      - alert: MySQLReplicationEnRetard
        expr: 'mysql_slave_status_seconds_behind_master - mysql_slave_status_sql_delay > @@SEUIL_REPLICATION_RETARD_S@@'
        for: 5m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "Réplica MySQL en retard de {{ $value | humanizeDuration }} sur {{ $labels.instance }}"
          description: "Seuil @@SEUIL_REPLICATION_RETARD_S@@ s dépassé."
      - alert: MySQLAttenteJournalInnoDB
        expr: 'rate(mysql_global_status_innodb_log_waits[15m]) > 10'
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "InnoDB attend l'écriture de son journal sur {{ $labels.instance }}"
          description: "innodb_log_buffer_size probablement trop petit."
      - alert: MySQLRedemarre
        expr: 'mysql_global_status_uptime < 300'
        labels: {severity: info, categorie: base-de-donnees}
        annotations:
          summary: "MySQL a redémarré sur {{ $labels.instance }}"
          description: "Démarré il y a {{ $value | humanizeDuration }}."
EOF
# -----------------------------------------------------------------------------
postgresql) cat <<'EOF' ;;
groups:
  - name: postgresql
    rules:
      - alert: PostgreSQLArrete
        expr: 'pg_up == 0'
        for: 1m
        labels: {severity: critical, categorie: base-de-donnees}
        annotations:
          summary: "PostgreSQL arrêté sur {{ $labels.instance }}"
          description: "L'agent n'arrive plus à se connecter à la base."
      - alert: PostgreSQLConnexionsSaturees
        expr: 'sum by (instance) (pg_stat_activity_count) / on (instance) max by (instance) (pg_settings_max_connections) * 100 > @@SEUIL_CONNEXIONS_PCT@@'
        for: 5m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "PostgreSQL : {{ $value | printf \"%.0f\" }} % des connexions utilisées sur {{ $labels.instance }}"
          description: "Envisager un pooler (PgBouncer) ou augmenter max_connections."
      - alert: PostgreSQLTransactionLongue
        expr: 'max by (instance, datname) (pg_stat_activity_max_tx_duration{datname!~"template.*",state="active"}) > @@SEUIL_PG_TRANSACTION_LONGUE_S@@'
        for: 2m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "Transaction active depuis {{ $value | humanizeDuration }} sur {{ $labels.datname }} ({{ $labels.instance }})"
          description: "Bloque le vacuum et peut verrouiller des tables. Voir pg_stat_activity."
      - alert: PostgreSQLTransactionInactiveOuverte
        expr: 'max by (instance, datname) (pg_stat_activity_max_tx_duration{datname!~"template.*",state="idle in transaction"}) > @@SEUIL_PG_TRANSACTION_LONGUE_S@@'
        for: 2m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "Session 'idle in transaction' depuis {{ $value | humanizeDuration }} sur {{ $labels.datname }}"
          description: "Une application ne termine pas ses transactions (COMMIT/ROLLBACK manquant)."
      - alert: PostgreSQLInterblocages
        expr: 'increase(pg_stat_database_deadlocks{datname!~"template.*"}[5m]) > 0'
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "Interblocages (deadlocks) sur {{ $labels.datname }} ({{ $labels.instance }})"
          description: "{{ $value | humanize }} deadlocks en 5 min."
      - alert: PostgreSQLTauxAnnulationEleve
        expr: 'sum by (instance, datname) (rate(pg_stat_database_xact_rollback{datname!~"template.*"}[5m])) / sum by (instance, datname) (rate(pg_stat_database_xact_rollback{datname!~"template.*"}[5m]) + rate(pg_stat_database_xact_commit{datname!~"template.*"}[5m])) > 0.10'
        for: 10m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "{{ $value | humanizePercentage }} des transactions annulées sur {{ $labels.datname }}"
          description: "Erreurs applicatives probables."
      - alert: PostgreSQLCacheInefficace
        expr: 'sum by (instance, datname) (rate(pg_stat_database_blks_hit{datname!~"template.*"}[30m])) / sum by (instance, datname) (rate(pg_stat_database_blks_hit{datname!~"template.*"}[30m]) + rate(pg_stat_database_blks_read{datname!~"template.*"}[30m])) < 0.90'
        for: 30m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "Taux de cache de {{ $value | humanizePercentage }} sur {{ $labels.datname }}"
          description: "shared_buffers insuffisant ou requêtes sans index (cible > 99 %)."
      - alert: PostgreSQLReplicationEnRetard
        expr: 'pg_replication_lag_seconds > @@SEUIL_REPLICATION_RETARD_S@@ and on (instance) pg_replication_is_replica == 1'
        for: 5m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "Réplica PostgreSQL en retard de {{ $value | humanizeDuration }} sur {{ $labels.instance }}"
          description: "Seuil @@SEUIL_REPLICATION_RETARD_S@@ s dépassé."
      - alert: PostgreSQLRedemarre
        expr: 'time() - pg_postmaster_start_time_seconds < 300'
        labels: {severity: info, categorie: base-de-donnees}
        annotations:
          summary: "PostgreSQL a redémarré sur {{ $labels.instance }}"
          description: "Démarré il y a moins de 5 minutes."
EOF
# -----------------------------------------------------------------------------
redis) cat <<'EOF' ;;
groups:
  - name: redis
    rules:
      - alert: RedisArrete
        expr: 'redis_up == 0'
        for: 1m
        labels: {severity: critical, categorie: base-de-donnees}
        annotations:
          summary: "Redis arrêté sur {{ $labels.instance }}"
          description: "L'agent n'arrive plus à se connecter à Redis."
      - alert: RedisMemoireSaturee
        expr: 'redis_memory_used_bytes / redis_memory_max_bytes * 100 > @@SEUIL_REDIS_MEMOIRE_PCT@@ and redis_memory_max_bytes > 0'
        for: 5m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "Redis utilise {{ $value | printf \"%.0f\" }} % de maxmemory sur {{ $labels.instance }}"
          description: "Au-delà, Redis évince des clés ou refuse les écritures selon maxmemory-policy."
      - alert: RedisEvictions
        expr: 'increase(redis_evicted_keys_total[5m]) > 0'
        for: 5m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "Redis évince des clés sur {{ $labels.instance }}"
          description: "{{ $value | humanize }} clés supprimées faute de mémoire en 5 min."
      - alert: RedisClientsSatures
        expr: 'redis_connected_clients / redis_config_maxclients * 100 > @@SEUIL_CONNEXIONS_PCT@@'
        for: 5m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "Redis : {{ $value | printf \"%.0f\" }} % des clients max sur {{ $labels.instance }}"
          description: "Fuite de connexions côté application probable."
      - alert: RedisConnexionsRejetees
        expr: 'increase(redis_rejected_connections_total[5m]) > 0'
        labels: {severity: critical, categorie: base-de-donnees}
        annotations:
          summary: "Redis rejette des connexions sur {{ $labels.instance }}"
          description: "{{ $value | humanize }} connexions rejetées en 5 min (maxclients atteint)."
      - alert: RedisSauvegardeEchouee
        expr: 'redis_rdb_last_bgsave_status == 0'
        labels: {severity: critical, categorie: base-de-donnees}
        annotations:
          summary: "La sauvegarde RDB de Redis a échoué sur {{ $labels.instance }}"
          description: "Redis peut refuser les écritures (stop-writes-on-bgsave-error). Vérifier disque et droits."
      - alert: RedisAOFEchoue
        expr: 'redis_aof_last_bgrewrite_status == 0'
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "La réécriture AOF de Redis a échoué sur {{ $labels.instance }}"
          description: "Vérifier l'espace disque."
      - alert: RedisReplicaPerdu
        expr: 'delta(redis_connected_slaves[5m]) < 0'
        labels: {severity: critical, categorie: base-de-donnees}
        annotations:
          summary: "Redis a perdu un réplica sur {{ $labels.instance }}"
          description: "Le nombre de réplicas connectés a diminué."
      - alert: RedisMasterInjoignable
        expr: 'redis_master_link_up == 0'
        for: 1m
        labels: {severity: critical, categorie: base-de-donnees}
        annotations:
          summary: "Le réplica Redis {{ $labels.instance }} a perdu son maître"
          description: "Lien de réplication coupé."
EOF
# -----------------------------------------------------------------------------
mongodb) cat <<'EOF' ;;
groups:
  - name: mongodb
    rules:
      - alert: MongoDBArrete
        expr: 'mongodb_up == 0'
        for: 1m
        labels: {severity: critical, categorie: base-de-donnees}
        annotations:
          summary: "MongoDB arrêté sur {{ $labels.instance }}"
          description: "L'agent n'arrive plus à se connecter à MongoDB."
      - alert: MongoDBConnexionsSaturees
        expr: 'mongodb_ss_connections{conn_type="current"} / ignoring (conn_type) (mongodb_ss_connections{conn_type="current"} + ignoring (conn_type) mongodb_ss_connections{conn_type="available"}) * 100 > @@SEUIL_CONNEXIONS_PCT@@'
        for: 5m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "MongoDB : {{ $value | printf \"%.0f\" }} % des connexions utilisées sur {{ $labels.instance }}"
          description: "Fuite de connexions ou pool applicatif mal dimensionné."
      - alert: MongoDBMembreReplicaSetKO
        expr: 'mongodb_rs_members_health == 0'
        for: 1m
        labels: {severity: critical, categorie: base-de-donnees}
        annotations:
          summary: "Un membre du replica set {{ $labels.set }} est en panne"
          description: "Membre {{ $labels.member_idx }} non sain vu depuis {{ $labels.instance }}."
      - alert: MongoDBReplicationEnRetard
        expr: 'mongodb_mongod_replset_member_replication_lag > @@SEUIL_REPLICATION_RETARD_S@@'
        for: 5m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "Réplication MongoDB en retard de {{ $value | humanizeDuration }}"
          description: "Membre {{ $labels.name }} du replica set {{ $labels.set }}."
      - alert: MongoDBAssertions
        expr: 'rate(mongodb_ss_asserts{assert_type=~"regular|msg"}[5m]) > 0'
        for: 5m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "MongoDB lève des assertions sur {{ $labels.instance }}"
          description: "Erreurs internes : consulter les logs mongod."
EOF
# -----------------------------------------------------------------------------
memcached) cat <<'EOF' ;;
groups:
  - name: memcached
    rules:
      - alert: MemcachedArrete
        expr: 'memcached_up == 0'
        for: 1m
        labels: {severity: critical, categorie: base-de-donnees}
        annotations:
          summary: "Memcached arrêté sur {{ $labels.instance }}"
          description: "L'agent n'arrive plus à se connecter à Memcached."
      - alert: MemcachedMemoireSaturee
        expr: 'memcached_current_bytes / memcached_limit_bytes * 100 > 95'
        for: 10m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "Memcached plein à {{ $value | printf \"%.0f\" }} % sur {{ $labels.instance }}"
          description: "Le cache évince des éléments : augmenter -m."
      - alert: MemcachedEvictions
        expr: 'rate(memcached_items_evicted_total[5m]) > 10'
        for: 10m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "Memcached évince {{ $value | printf \"%.0f\" }} éléments/s sur {{ $labels.instance }}"
          description: "Cache sous-dimensionné : taux de succès en baisse."
      - alert: MemcachedConnexionsSaturees
        expr: 'memcached_current_connections / memcached_max_connections * 100 > @@SEUIL_CONNEXIONS_PCT@@'
        for: 5m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "Memcached : {{ $value | printf \"%.0f\" }} % des connexions max"
          description: "Augmenter -c ou vérifier les clients."
EOF
# -----------------------------------------------------------------------------
elasticsearch) cat <<'EOF' ;;
groups:
  - name: elasticsearch
    rules:
      - alert: ElasticsearchInjoignable
        expr: 'elasticsearch_cluster_health_up == 0'
        for: 1m
        labels: {severity: critical, categorie: base-de-donnees}
        annotations:
          summary: "Elasticsearch injoignable depuis {{ $labels.instance }}"
          description: "L'agent n'obtient plus l'état du cluster."
      - alert: ElasticsearchClusterRouge
        expr: 'elasticsearch_cluster_health_status{color="red"} == 1'
        for: 2m
        labels: {severity: critical, categorie: base-de-donnees}
        annotations:
          summary: "Cluster Elasticsearch {{ $labels.cluster }} en état ROUGE"
          description: "Des shards primaires ne sont pas alloués : données indisponibles."
      - alert: ElasticsearchClusterJaune
        expr: 'elasticsearch_cluster_health_status{color="yellow"} == 1'
        for: 20m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "Cluster Elasticsearch {{ $labels.cluster }} en état JAUNE"
          description: "Des réplicas ne sont pas alloués : plus de redondance."
      - alert: ElasticsearchNoeudPerdu
        expr: 'elasticsearch_cluster_health_number_of_nodes < max_over_time(elasticsearch_cluster_health_number_of_nodes[1h])'
        for: 5m
        labels: {severity: critical, categorie: base-de-donnees}
        annotations:
          summary: "Le cluster {{ $labels.cluster }} a perdu un nœud"
          description: "Il reste {{ $value }} nœuds."
      - alert: ElasticsearchShardsNonAlloues
        expr: 'elasticsearch_cluster_health_unassigned_shards > 0'
        for: 15m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "{{ $value }} shards non alloués dans {{ $labels.cluster }}"
          description: "Voir : GET _cluster/allocation/explain."
      - alert: ElasticsearchHeapSaturee
        expr: 'elasticsearch_jvm_memory_used_bytes{area="heap"} / elasticsearch_jvm_memory_max_bytes{area="heap"} * 100 > @@SEUIL_JVM_HEAP_PCT@@'
        for: 10m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "Heap JVM à {{ $value | printf \"%.0f\" }} % sur le nœud {{ $labels.name }}"
          description: "Risque de pauses GC longues et de disjoncteurs (circuit breakers)."
      - alert: ElasticsearchDisqueSeuilBas
        expr: '(1 - elasticsearch_filesystem_data_available_bytes / elasticsearch_filesystem_data_size_bytes) * 100 > 85'
        for: 5m
        labels: {severity: warning, categorie: base-de-donnees}
        annotations:
          summary: "Disque du nœud {{ $labels.name }} à {{ $value | printf \"%.0f\" }} %"
          description: "Au-delà de 85 % (low watermark) aucun nouveau shard n'est alloué ; à 95 % les index passent en lecture seule."
EOF
# -----------------------------------------------------------------------------
nginx) cat <<'EOF' ;;
groups:
  - name: nginx
    rules:
      - alert: NginxArrete
        expr: 'nginx_up == 0'
        for: 1m
        labels: {severity: critical, categorie: web}
        annotations:
          summary: "Nginx arrêté sur {{ $labels.instance }}"
          description: "La page stub_status ne répond plus."
      - alert: NginxConnexionsElevees
        expr: 'nginx_connections_active > @@SEUIL_NGINX_CONNEXIONS@@'
        for: 10m
        labels: {severity: warning, categorie: web}
        annotations:
          summary: "Nginx : {{ $value }} connexions actives sur {{ $labels.instance }}"
          description: "Seuil @@SEUIL_NGINX_CONNEXIONS@@ dépassé : pic de trafic ou backends lents."
      - alert: NginxConnexionsAbandonnees
        expr: 'rate(nginx_connections_accepted[5m]) - rate(nginx_connections_handled[5m]) > 0'
        for: 5m
        labels: {severity: critical, categorie: web}
        annotations:
          summary: "Nginx abandonne des connexions sur {{ $labels.instance }}"
          description: "worker_connections ou limite de fichiers atteinte."
EOF
# -----------------------------------------------------------------------------
apache) cat <<'EOF' ;;
groups:
  - name: apache
    rules:
      - alert: ApacheArrete
        expr: 'apache_up == 0'
        for: 1m
        labels: {severity: critical, categorie: web}
        annotations:
          summary: "Apache arrêté sur {{ $labels.instance }}"
          description: "La page server-status ne répond plus."
      - alert: ApacheWorkersSatures
        expr: 'apache_workers{state="busy"} / ignoring (state) sum without (state) (apache_workers) * 100 > 80'
        for: 10m
        labels: {severity: warning, categorie: web}
        annotations:
          summary: "Apache : {{ $value | printf \"%.0f\" }} % des workers occupés sur {{ $labels.instance }}"
          description: "Augmenter MaxRequestWorkers ou vérifier les temps de réponse applicatifs."
      - alert: ApacheRedemarre
        expr: 'apache_uptime_seconds_total < 300'
        labels: {severity: info, categorie: web}
        annotations:
          summary: "Apache a redémarré sur {{ $labels.instance }}"
          description: "Démarré il y a moins de 5 minutes."
EOF
# -----------------------------------------------------------------------------
phpfpm) cat <<'EOF' ;;
groups:
  - name: phpfpm
    rules:
      - alert: PHPFPMArrete
        expr: 'phpfpm_up == 0'
        for: 1m
        labels: {severity: critical, categorie: web}
        annotations:
          summary: "PHP-FPM injoignable sur {{ $labels.instance }}"
          description: "La page de statut du pool {{ $labels.pool }} ne répond plus."
      - alert: PHPFPMPoolSature
        expr: 'increase(phpfpm_max_children_reached[5m]) > 0'
        labels: {severity: warning, categorie: web}
        annotations:
          summary: "Pool PHP-FPM {{ $labels.pool }} saturé (pm.max_children atteint)"
          description: "Des requêtes attendent un processus libre sur {{ $labels.instance }}."
      - alert: PHPFPMFileAttente
        expr: 'phpfpm_listen_queue > @@SEUIL_PHPFPM_FILE_ATTENTE@@'
        for: 5m
        labels: {severity: warning, categorie: web}
        annotations:
          summary: "{{ $value }} requêtes en file d'attente sur le pool {{ $labels.pool }}"
          description: "Le pool ne suit pas la charge."
      - alert: PHPFPMRequetesLentes
        expr: 'increase(phpfpm_slow_requests[5m]) > 5'
        labels: {severity: warning, categorie: web}
        annotations:
          summary: "Requêtes PHP lentes sur le pool {{ $labels.pool }}"
          description: "{{ $value | humanize }} requêtes lentes en 5 min (voir slowlog)."
EOF
# -----------------------------------------------------------------------------
haproxy) cat <<'EOF' ;;
groups:
  - name: haproxy
    rules:
      - alert: HAProxyBackendSansServeur
        expr: 'haproxy_backend_active_servers + haproxy_backend_backup_servers == 0'
        for: 1m
        labels: {severity: critical, categorie: web}
        annotations:
          summary: "Backend HAProxy {{ $labels.proxy }} sans aucun serveur actif"
          description: "Le service est indisponible pour les utilisateurs ({{ $labels.instance }})."
      - alert: HAProxyServeurDown
        expr: 'haproxy_server_status{state="DOWN"} == 1'
        for: 2m
        labels: {severity: warning, categorie: web}
        annotations:
          summary: "Serveur {{ $labels.server }} DOWN dans le backend {{ $labels.proxy }}"
          description: "Health check en échec."
      - alert: HAProxyErreurs5xx
        expr: 'sum by (instance, proxy) (rate(haproxy_backend_http_responses_total{code="5xx"}[5m])) / sum by (instance, proxy) (rate(haproxy_backend_http_responses_total[5m])) * 100 > @@SEUIL_HTTP_ERREURS_PCT@@'
        for: 5m
        labels: {severity: warning, categorie: web}
        annotations:
          summary: "{{ $value | printf \"%.1f\" }} % d'erreurs 5xx sur le backend {{ $labels.proxy }}"
          description: "Seuil @@SEUIL_HTTP_ERREURS_PCT@@ % dépassé."
      - alert: HAProxySessionsSaturees
        expr: 'haproxy_frontend_current_sessions / haproxy_frontend_limit_sessions * 100 > 80 and haproxy_frontend_limit_sessions > 0'
        for: 5m
        labels: {severity: warning, categorie: web}
        annotations:
          summary: "Frontend {{ $labels.proxy }} à {{ $value | printf \"%.0f\" }} % de sa limite de sessions"
          description: "Augmenter maxconn."
EOF
# -----------------------------------------------------------------------------
rabbitmq) cat <<'EOF' ;;
groups:
  - name: rabbitmq
    rules:
      - alert: RabbitMQAlarmeMemoire
        expr: 'rabbitmq_alarms_memory_used_watermark == 1'
        labels: {severity: critical, categorie: messagerie}
        annotations:
          summary: "RabbitMQ : alarme mémoire sur {{ $labels.instance }}"
          description: "Les éditeurs (publishers) sont bloqués tant que l'alarme est active."
      - alert: RabbitMQAlarmeDisque
        expr: 'rabbitmq_alarms_free_disk_space_watermark == 1'
        labels: {severity: critical, categorie: messagerie}
        annotations:
          summary: "RabbitMQ : alarme espace disque sur {{ $labels.instance }}"
          description: "Les éditeurs sont bloqués : libérer de l'espace disque."
      - alert: RabbitMQMessagesEnAttente
        expr: 'sum by (instance) (rabbitmq_queue_messages_ready) > @@SEUIL_RABBITMQ_MESSAGES@@'
        for: 15m
        labels: {severity: warning, categorie: messagerie}
        annotations:
          summary: "{{ $value }} messages en attente sur {{ $labels.instance }}"
          description: "Les consommateurs ne suivent pas (seuil @@SEUIL_RABBITMQ_MESSAGES@@)."
      - alert: RabbitMQMessagesNonAcquittes
        expr: 'sum by (instance) (rabbitmq_queue_messages_unacked) > @@SEUIL_RABBITMQ_MESSAGES@@'
        for: 15m
        labels: {severity: warning, categorie: messagerie}
        annotations:
          summary: "{{ $value }} messages non acquittés sur {{ $labels.instance }}"
          description: "Consommateurs bloqués ou trop lents."
      - alert: RabbitMQSansConsommateur
        expr: 'sum by (instance) (rabbitmq_queue_consumers) == 0 and sum by (instance) (rabbitmq_queue_messages_ready) > 0'
        for: 10m
        labels: {severity: warning, categorie: messagerie}
        annotations:
          summary: "Aucun consommateur connecté à RabbitMQ sur {{ $labels.instance }}"
          description: "Des messages s'accumulent sans être traités."
      - alert: RabbitMQDescripteursFichiers
        expr: 'rabbitmq_process_open_fds / rabbitmq_process_max_fds > 0.8'
        for: 5m
        labels: {severity: warning, categorie: messagerie}
        annotations:
          summary: "RabbitMQ utilise {{ $value | humanizePercentage }} des descripteurs de fichiers"
          description: "Augmenter LimitNOFILE."
EOF
# -----------------------------------------------------------------------------
kafka) cat <<'EOF' ;;
groups:
  - name: kafka
    rules:
      - alert: KafkaBrokerPerdu
        expr: 'kafka_brokers < max_over_time(kafka_brokers[1h])'
        for: 2m
        labels: {severity: critical, categorie: messagerie}
        annotations:
          summary: "Le cluster Kafka a perdu un broker"
          description: "Il reste {{ $value }} brokers ({{ $labels.instance }})."
      - alert: KafkaPartitionSansLeader
        expr: 'kafka_topic_partition_leader == -1'
        for: 1m
        labels: {severity: critical, categorie: messagerie}
        annotations:
          summary: "Partition {{ $labels.partition }} du topic {{ $labels.topic }} sans leader"
          description: "La partition est indisponible en lecture et écriture."
      - alert: KafkaPartitionsSousRepliquees
        expr: 'sum by (instance, topic) (kafka_topic_partition_under_replicated_partition) > 0'
        for: 5m
        labels: {severity: warning, categorie: messagerie}
        annotations:
          summary: "{{ $value }} partitions sous-répliquées sur le topic {{ $labels.topic }}"
          description: "Perte de redondance : un broker est lent ou absent."
      - alert: KafkaRetardConsommateur
        expr: 'sum by (instance, consumergroup, topic) (kafka_consumergroup_lag) > @@SEUIL_KAFKA_LAG@@'
        for: 10m
        labels: {severity: warning, categorie: messagerie}
        annotations:
          summary: "Groupe {{ $labels.consumergroup }} en retard de {{ $value }} messages sur {{ $labels.topic }}"
          description: "Les consommateurs ne suivent pas (seuil @@SEUIL_KAFKA_LAG@@)."
EOF
# -----------------------------------------------------------------------------
jvm) cat <<'EOF' ;;
groups:
  - name: jvm
    rules:
      - alert: JVMHeapSaturee
        expr: 'sum by (instance, job) (jvm_memory_used_bytes{area="heap"}) / sum by (instance, job) (jvm_memory_max_bytes{area="heap"} > 0) * 100 > @@SEUIL_JVM_HEAP_PCT@@'
        for: 10m
        labels: {severity: warning, categorie: application}
        annotations:
          summary: "Heap Java à {{ $value | printf \"%.0f\" }} % sur {{ $labels.instance }}"
          description: "Risque d'OutOfMemoryError : fuite mémoire ou -Xmx insuffisant."
      - alert: JVMTempsGCEleve
        expr: '(sum by (instance, job) (rate(jvm_gc_collection_seconds_sum[5m])) or sum by (instance, job) (rate(jvm_gc_pause_seconds_sum[5m]))) * 100 > @@SEUIL_JVM_GC_PCT@@'
        for: 10m
        labels: {severity: warning, categorie: application}
        annotations:
          summary: "La JVM passe {{ $value | printf \"%.0f\" }} % de son temps en GC sur {{ $labels.instance }}"
          description: "L'application est ralentie par le ramasse-miettes (seuil @@SEUIL_JVM_GC_PCT@@ %)."
      - alert: JVMThreadsNombreux
        expr: '(jvm_threads_current or jvm_threads_live_threads) > @@SEUIL_JVM_THREADS@@'
        for: 10m
        labels: {severity: warning, categorie: application}
        annotations:
          summary: "{{ $value }} threads Java sur {{ $labels.instance }}"
          description: "Fuite de threads probable (seuil @@SEUIL_JVM_THREADS@@)."
      - alert: JVMInterblocageThreads
        expr: 'jvm_threads_deadlocked > 0'
        for: 1m
        labels: {severity: critical, categorie: application}
        annotations:
          summary: "Interblocage de threads Java sur {{ $labels.instance }}"
          description: "{{ $value }} threads bloqués mutuellement : faire un thread dump (jstack)."
      - alert: ApplicationErreursHTTP5xx
        expr: 'sum by (instance, job) (rate(http_server_requests_seconds_count{status=~"5.."}[5m])) / sum by (instance, job) (rate(http_server_requests_seconds_count[5m])) * 100 > @@SEUIL_HTTP_ERREURS_PCT@@'
        for: 5m
        labels: {severity: critical, categorie: application}
        annotations:
          summary: "{{ $value | printf \"%.1f\" }} % d'erreurs HTTP 5xx sur {{ $labels.instance }}"
          description: "Seuil @@SEUIL_HTTP_ERREURS_PCT@@ % dépassé (Spring Boot)."
      - alert: ApplicationLatenceHTTP
        expr: 'sum by (instance, job) (rate(http_server_requests_seconds_sum[5m])) / sum by (instance, job) (rate(http_server_requests_seconds_count[5m])) > @@SEUIL_HTTP_LATENCE_S@@'
        for: 10m
        labels: {severity: warning, categorie: application}
        annotations:
          summary: "Temps de réponse moyen de {{ $value | printf \"%.2f\" }} s sur {{ $labels.instance }}"
          description: "Seuil @@SEUIL_HTTP_LATENCE_S@@ s dépassé."
      - alert: ApplicationPoolConnexionsBDSature
        expr: 'hikaricp_connections_pending > 0 and hikaricp_connections_active >= hikaricp_connections_max'
        for: 5m
        labels: {severity: warning, categorie: application}
        annotations:
          summary: "Pool de connexions base de données saturé ({{ $labels.pool }}) sur {{ $labels.instance }}"
          description: "Des requêtes attendent une connexion HikariCP."
EOF
# -----------------------------------------------------------------------------
process) cat <<'EOF' ;;
groups:
  - name: processus
    rules:
      - alert: ProcessusAbsent
        expr: 'namedprocess_namegroup_num_procs == 0'
        for: 1m
        labels: {severity: critical, categorie: application}
        annotations:
          summary: "Processus {{ $labels.groupname }} absent sur {{ $labels.instance }}"
          description: "Plus aucune instance du processus ne tourne."
      - alert: ProcessusDisparuDesMetriques
        expr: 'count by (instance, groupname) (namedprocess_namegroup_num_procs offset 15m) unless count by (instance, groupname) (namedprocess_namegroup_num_procs)'
        labels: {severity: critical, categorie: application}
        annotations:
          summary: "Processus {{ $labels.groupname }} disparu des métriques sur {{ $labels.instance }}"
          description: "Le processus n'est plus détecté depuis le redémarrage de l'agent : il est probablement arrêté."
      - alert: ProcessusRedemarre
        expr: 'changes(namedprocess_namegroup_oldest_start_time_seconds[10m]) > 0'
        labels: {severity: info, categorie: application}
        annotations:
          summary: "Processus {{ $labels.groupname }} redémarré sur {{ $labels.instance }}"
          description: "Redémarrage détecté dans les 10 dernières minutes."
      - alert: ProcessusMemoireElevee
        expr: 'namedprocess_namegroup_memory_bytes{memtype="resident"} / 1024 / 1024 / 1024 > @@SEUIL_PROCESSUS_MEMOIRE_GO@@'
        for: 15m
        labels: {severity: warning, categorie: application}
        annotations:
          summary: "{{ $labels.groupname }} utilise {{ $value | printf \"%.1f\" }} Go de mémoire"
          description: "Seuil @@SEUIL_PROCESSUS_MEMOIRE_GO@@ Go dépassé sur {{ $labels.instance }}."
      - alert: ProcessusDescripteursFichiers
        expr: 'namedprocess_namegroup_worst_fd_ratio > 0.8'
        for: 10m
        labels: {severity: warning, categorie: application}
        annotations:
          summary: "{{ $labels.groupname }} utilise {{ $value | humanizePercentage }} de ses descripteurs de fichiers"
          description: "Risque d'erreurs 'Too many open files'."
EOF
# -----------------------------------------------------------------------------
docker) cat <<'EOF' ;;
groups:
  - name: conteneurs
    rules:
      - alert: ConteneurDisparu
        expr: 'time() - container_last_seen{name!=""} > 120'
        labels: {severity: warning, categorie: application}
        annotations:
          summary: "Le conteneur {{ $labels.name }} a disparu de {{ $labels.instance }}"
          description: "Arrêté ou supprimé depuis plus de 2 minutes."
      - alert: ConteneurMemoireLimite
        expr: 'container_memory_working_set_bytes{name!=""} / container_spec_memory_limit_bytes{name!=""} * 100 > @@SEUIL_CONTENEUR_MEMOIRE_PCT@@ and container_spec_memory_limit_bytes{name!=""} > 0'
        for: 5m
        labels: {severity: warning, categorie: application}
        annotations:
          summary: "Conteneur {{ $labels.name }} à {{ $value | printf \"%.0f\" }} % de sa limite mémoire"
          description: "Il sera tué (OOM) s'il atteint sa limite."
      - alert: ConteneurTueOOM
        expr: 'increase(container_oom_events_total{name!=""}[10m]) > 0'
        labels: {severity: warning, categorie: application}
        annotations:
          summary: "Conteneur {{ $labels.name }} tué par manque de mémoire"
          description: "Sur {{ $labels.instance }}."
      - alert: ConteneurCPUSature
        expr: 'sum by (instance, name) (rate(container_cpu_cfs_throttled_seconds_total{name!=""}[5m])) > 1'
        for: 15m
        labels: {severity: warning, categorie: application}
        annotations:
          summary: "Conteneur {{ $labels.name }} bridé en CPU"
          description: "La limite CPU du conteneur est trop basse."
EOF
# -----------------------------------------------------------------------------
application) cat <<'EOF' ;;
groups:
  - name: application
    rules:
      - alert: ApplicationErreurs5xx
        expr: 'sum by (instance, job) (rate(http_requests_total{job=~"application.*",code=~"5.."}[5m])) / sum by (instance, job) (rate(http_requests_total{job=~"application.*"}[5m])) * 100 > @@SEUIL_HTTP_ERREURS_PCT@@'
        for: 5m
        labels: {severity: critical, categorie: application}
        annotations:
          summary: "{{ $value | printf \"%.1f\" }} % d'erreurs 5xx sur {{ $labels.instance }}"
          description: "Application instrumentée (métrique http_requests_total)."
      - alert: ApplicationRedemarre
        expr: 'time() - process_start_time_seconds{job=~"application.*"} < 300'
        labels: {severity: info, categorie: application}
        annotations:
          summary: "{{ $labels.job }} a redémarré sur {{ $labels.instance }}"
          description: "Démarrée il y a moins de 5 minutes."
      - alert: ApplicationDescripteursFichiers
        expr: 'process_open_fds{job=~"application.*"} / process_max_fds{job=~"application.*"} > 0.8'
        for: 10m
        labels: {severity: warning, categorie: application}
        annotations:
          summary: "{{ $labels.job }} utilise {{ $value | humanizePercentage }} de ses descripteurs de fichiers"
          description: "Sur {{ $labels.instance }}."
EOF
    *) return 1 ;;
    esac
}

# regles_generer <fichier> : contenu final (seuils appliqués)
regles_generer() {
    regles_contenu "$1" | FS_FILTRE="${FS_FILTRE}" rendu
}

# Liste lisible des règles (nom, sévérité, résumé)
regles_lister() {
    local f
    for f in "$@"; do
        printf '\n %s%s%s\n' "${C_GRAS}" "${f}" "${C_0}"
        regles_generer "${f}" | awk '
            /- alert:/ {nom=$3}
            /severity:/ {match($0, /severity: [a-z]+/); sev=substr($0, RSTART+10, RLENGTH-10)}
            /summary:/ {sub(/^ *summary: "/, ""); sub(/"$/, ""); printf "   %-36s %-9s %s\n", nom, sev, $0}'
    done
}

# =============================================================================
#  GÉNÉRATION DES CONFIGURATIONS
# =============================================================================
generer_prometheus_yml() {
    PROM_CIBLE="$(adresse_locale "${PROMETHEUS_LISTEN_ADDRESS}"):${PROMETHEUS_PORT}"
    AM_CIBLE="$(adresse_locale "${ALERTMANAGER_LISTEN_ADDRESS}"):${ALERTMANAGER_PORT}"
    rendu <<'EOF'
# =============================================================================
#  Prometheus — @@MARQUEUR@@
#  Fichier régénéré par : prometheus-bundle.sh 02 appliquer
#  Jobs applicatifs : @@PROMETHEUS_CONF_DIR@@/scrape.d/   Cibles : @@PROMETHEUS_CONF_DIR@@/targets/
# =============================================================================
global:
  scrape_interval: @@PROMETHEUS_SCRAPE_INTERVAL@@
  evaluation_interval: @@PROMETHEUS_EVALUATION_INTERVAL@@
  external_labels:
    environnement: "@@PROMETHEUS_CLUSTER_LABEL@@"

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["@@AM_CIBLE@@"]

rule_files:
  - "@@PROMETHEUS_CONF_DIR@@/rules/*.yml"

# Un fichier par application, ajouté par : prometheus-bundle.sh 03 cible ...
scrape_config_files:
  - "@@PROMETHEUS_CONF_DIR@@/scrape.d/*.yml"

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["@@PROM_CIBLE@@"]
  - job_name: "alertmanager"
    static_configs:
      - targets: ["@@AM_CIBLE@@"]
EOF
}

unite_prometheus() {
    rendu <<'EOF'
# @@MARQUEUR@@
[Unit]
Description=Prometheus - supervision et base de séries temporelles
Documentation=https://prometheus.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=@@PROMETHEUS_USER@@
Group=@@PROMETHEUS_USER@@
ExecStart=@@BIN_DIR@@/prometheus \
  --config.file=@@PROMETHEUS_CONF_DIR@@/prometheus.yml \
  --storage.tsdb.path=@@PROMETHEUS_DATA_DIR@@ \
  --storage.tsdb.retention.time=@@PROMETHEUS_RETENTION_TIME@@ \
  --storage.tsdb.retention.size=@@PROMETHEUS_RETENTION_SIZE@@ \
  --web.listen-address=@@PROMETHEUS_LISTEN_ADDRESS@@:@@PROMETHEUS_PORT@@ \
  --web.enable-lifecycle
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s
TimeoutStopSec=120s
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=@@PROMETHEUS_DATA_DIR@@

[Install]
WantedBy=multi-user.target
EOF
}

unite_alertmanager() {
    rendu <<'EOF'
# @@MARQUEUR@@
[Unit]
Description=Alertmanager - routage et notification des alertes
Documentation=https://prometheus.io/docs/alerting/latest/alertmanager/
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=@@ALERTMANAGER_USER@@
Group=@@ALERTMANAGER_USER@@
ExecStart=@@BIN_DIR@@/alertmanager \
  --config.file=@@ALERTMANAGER_CONF_DIR@@/alertmanager.yml \
  --storage.path=@@ALERTMANAGER_DATA_DIR@@ \
  --data.retention=@@ALERTMANAGER_DATA_RETENTION@@ \
  --web.listen-address=@@ALERTMANAGER_LISTEN_ADDRESS@@:@@ALERTMANAGER_PORT@@ \
  --cluster.listen-address=
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=@@ALERTMANAGER_DATA_DIR@@

[Install]
WantedBy=multi-user.target
EOF
}

# Gabarits de messages en français, partagés par tous les canaux
modele_messages_fr() {
    cat <<'EOF'
{{/* Prometheus-bundle : messages d'alerte en français */}}
{{ define "fr.titre" }}{{ if eq .Status "firing" }}🔴 ALERTE{{ else }}✅ RÉSOLU{{ end }}{{ with .CommonLabels.severity }} [{{ . | toUpper }}]{{ end }} {{ .CommonLabels.alertname }}{{ if gt (len .Alerts) 1 }} ({{ len .Alerts }}){{ end }}{{ end }}

{{ define "fr.texte" }}{{ range .Alerts }}{{ if eq .Status "firing" }}🔴{{ else }}✅{{ end }} {{ .Annotations.summary }}
{{ .Annotations.description }}
Instance : {{ .Labels.instance }} | Job : {{ .Labels.job }} | Depuis : {{ .StartsAt.Local.Format "02/01/2006 15:04" }}
{{ end }}{{ end }}

{{ define "fr.html" }}{{ range .Alerts }}<b>{{ if eq .Status "firing" }}🔴{{ else }}✅{{ end }} {{ .Annotations.summary }}</b>
{{ .Annotations.description }}
<i>Instance : {{ .Labels.instance }} | Depuis : {{ .StartsAt.Local.Format "02/01/2006 15:04" }}</i>
{{ end }}{{ end }}

{{ define "fr.email" }}<h3 style="font-family:sans-serif">{{ template "fr.titre" . }}</h3>
<table style="font-family:sans-serif;border-collapse:collapse" cellpadding="6">
{{ range .Alerts }}<tr style="border-bottom:1px solid #ddd"><td>{{ if eq .Status "firing" }}🔴{{ else }}✅{{ end }}</td>
<td><b>{{ .Annotations.summary }}</b><br>{{ .Annotations.description }}<br>
<small>Instance : {{ .Labels.instance }} — Job : {{ .Labels.job }} — Depuis : {{ .StartsAt.Local.Format "02/01/2006 15:04" }}</small></td></tr>
{{ end }}</table>{{ end }}
EOF
}

# Assemble alertmanager.yml à partir des canaux de canaux.d/
generer_alertmanager_yml() {
    local d="${ALERTMANAGER_CONF_DIR}/canaux.d" f nom sev
    cat <<EOF
# =============================================================================
#  Alertmanager — ${MARQUEUR}
#  NE PAS MODIFIER : fichier régénéré à partir de ${d}/
#  Gestion des canaux : prometheus-bundle.sh 04
# =============================================================================
global:
  resolve_timeout: 5m

templates:
  - "${ALERTMANAGER_CONF_DIR}/templates/*.tmpl"

route:
  receiver: "aucun"
  group_by: ["alertname", "job", "instance"]
  group_wait: ${ALERT_GROUP_WAIT}
  group_interval: ${ALERT_GROUP_INTERVAL}
  repeat_interval: ${ALERT_REPEAT_INTERVAL}
  routes:
    # L'alerte Watchdog (toujours active) n'est envoyée à personne
    - receiver: "aucun"
      matchers: ['alertname="Watchdog"']
EOF
    for f in "${d}"/*.yml; do
        [[ -f "${f}" ]] || continue
        nom="$(basename "${f}" .yml)"
        sev="$(awk -F': ' '/^# severites:/ {print $2}' "${f}")"
        cat <<EOF
    - receiver: "${nom}"
      matchers: ['severity=~"${sev:-critical|warning}"']
      continue: true
EOF
    done
    cat <<EOF

receivers:
  - name: "aucun"
EOF
    for f in "${d}"/*.yml; do
        [[ -f "${f}" ]] && grep -v '^#' "${f}"
    done
    cat <<'EOF'

inhibit_rules:
  # Une alerte critique masque l'avertissement équivalent sur la même instance
  - source_matchers: ['severity="critical"']
    target_matchers: ['severity=~"warning|info"']
    equal: ["alertname", "instance"]
  # Panne générale d'un job : on n'envoie pas une alerte par cible
  - source_matchers: ['alertname="MajoriteCiblesInjoignables"']
    target_matchers: ['alertname="CibleInjoignable"']
    equal: ["job"]
EOF
}

# Applications activées = fichiers présents dans scrape.d/
applications_actives() {
    local f
    for f in "${PROMETHEUS_CONF_DIR}"/scrape.d/*.yml; do
        [[ -f "${f}" ]] && basename "${f}" .yml
    done
}

# Déploie les règles : base + règles des applications activées
deployer_regles() {
    local app fichiers=(base) r
    while read -r app; do
        [[ -n "${app}" ]] || continue
        catalogue "${app}" || continue
        [[ " ${fichiers[*]} " == *" ${APP_REGLES} "* ]] || fichiers+=("${APP_REGLES}")
    done < <(applications_actives)
    install -d -m 0755 -o root -g "${PROMETHEUS_USER}" "${PROMETHEUS_CONF_DIR}/rules"
    for r in "${fichiers[@]}"; do
        regles_generer "${r}" | ecrire_fichier "${PROMETHEUS_CONF_DIR}/rules/${r}.yml" "root:${PROMETHEUS_USER}" 0640 || exit 1
    done
    # Retire les règles d'applications désactivées (fichiers générés par le bundle)
    for r in "${PROMETHEUS_CONF_DIR}"/rules/*.yml; do
        [[ -f "${r}" ]] || continue
        local n; n="$(basename "${r}" .yml)"
        if [[ " ${REGLES_FICHIERS[*]} " == *" ${n} "* && " ${fichiers[*]} " != *" ${n} "* ]]; then
            rm -f "${r}"
        fi
    done
    log_ok "Règles d'alerte déployées : ${fichiers[*]}"
}

valider_prometheus() {
    "${BIN_DIR}/promtool" check config "${PROMETHEUS_CONF_DIR}/prometheus.yml" >/dev/null 2>&1 \
        || { "${BIN_DIR}/promtool" check config "${PROMETHEUS_CONF_DIR}/prometheus.yml"; return 1; }
}
valider_alertmanager() {
    "${BIN_DIR}/amtool" check-config "${ALERTMANAGER_CONF_DIR}/alertmanager.yml" >/dev/null 2>&1 \
        || { "${BIN_DIR}/amtool" check-config "${ALERTMANAGER_CONF_DIR}/alertmanager.yml"; return 1; }
}

recharger_prometheus() {
    valider_prometheus || { log_error "Configuration Prometheus invalide : non rechargée"; return 1; }
    if systemctl is-active --quiet prometheus 2>/dev/null; then
        http_post "$(prom_url)/-/reload" 2>/dev/null || systemctl reload prometheus
        log_ok "Prometheus rechargé"
    fi
}
recharger_alertmanager() {
    valider_alertmanager || { log_error "Configuration Alertmanager invalide : non rechargée"; return 1; }
    if systemctl is-active --quiet alertmanager 2>/dev/null; then
        http_post "$(am_url)/-/reload" 2>/dev/null || systemctl reload alertmanager
        log_ok "Alertmanager rechargé"
    fi
}

# Régénère alertmanager.yml ; restaure l'ancienne version si invalide
appliquer_alertmanager() {
    local cfg="${ALERTMANAGER_CONF_DIR}/alertmanager.yml" bak
    install -d -m 0750 -o root -g "${ALERTMANAGER_USER}" "${ALERTMANAGER_CONF_DIR}/canaux.d"
    install -d -m 0755 -o root -g "${ALERTMANAGER_USER}" "${ALERTMANAGER_CONF_DIR}/templates"
    modele_messages_fr | ecrire_fichier "${ALERTMANAGER_CONF_DIR}/templates/francais.tmpl" "root:${ALERTMANAGER_USER}" 0644 || exit 1
    bak="$(workdir)/alertmanager.yml.prec"
    [[ -f "${cfg}" ]] && cp -p "${cfg}" "${bak}"
    generer_alertmanager_yml | ecrire_fichier "${cfg}" "root:${ALERTMANAGER_USER}" 0640 || exit 1
    if ! valider_alertmanager; then
        [[ -f "${bak}" ]] && cp -p "${bak}" "${cfg}"
        log_error "Configuration Alertmanager invalide : version précédente restaurée"
        return 1
    fi
    recharger_alertmanager
}

# =============================================================================
#  00 — VÉRIFICATION PRÉLIMINAIRE
# =============================================================================
etape_00() {
    [[ "${1:-}" == "aide" ]] && { cat <<EOF
00 — Vérification préliminaire (ne modifie rien)
  ${SCRIPT_NAME} 00
Contrôle : root, Linux/systemd, architecture, commandes, mémoire, disque,
ports, installation existante, accès aux archives, SELinux, pare-feu.
Code retour 1 si une erreur bloquante est détectée.
EOF
    return 0; }

    local erreurs=0 avert=0
    ok()   { log_ok "$*"; }
    warn() { log_warn "$*"; avert=$((avert + 1)); }
    ko()   { log_error "$*"; erreurs=$((erreurs + 1)); }

    titre "00 - Vérification préliminaire"
    log_info "Prometheus ${PROMETHEUS_VERSION} / Alertmanager ${ALERTMANAGER_VERSION}"

    titre "Système"
    [[ ${EUID} -eq 0 ]] && ok "Exécution en tant que root" || ko "Exécuter en tant que root (sudo)"
    log_info "Système : $(detect_os) — noyau $(uname -r)"
    [[ "$(uname -s)" == "Linux" ]] && ok "Système Linux" || ko "Système non Linux"
    local arch; arch="$(detect_arch)"
    [[ "${arch}" != "unsupported" ]] && ok "Architecture $(uname -m) (paquets linux-${arch})" \
                                     || ko "Architecture non supportée : $(uname -m)"
    if cmd_exists systemctl && [[ -d /run/systemd/system ]]; then ok "systemd actif"
    else ko "systemd n'est pas actif"; fi

    titre "Commandes"
    local c manquantes=()
    for c in tar gzip install useradd groupadd getent sha256sum awk sed grep mktemp; do
        cmd_exists "${c}" || manquantes+=("${c}")
    done
    (( ${#manquantes[@]} == 0 )) && ok "Commandes de base présentes" || ko "Commandes manquantes : ${manquantes[*]}"
    if cmd_exists curl || cmd_exists wget; then ok "Client HTTP : $(cmd_exists curl && echo curl || echo wget)"
    else ko "curl ou wget requis"; fi
    cmd_exists ss || cmd_exists netstat || warn "ss/netstat absents : contrôle des ports approximatif"

    titre "Ressources"
    local mem; mem=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    (( mem >= 1024 )) && ok "Mémoire : ${mem} Mo" || warn "Mémoire faible : ${mem} Mo (1024 Mo conseillés)"
    local d p libre
    for d in "${PROMETHEUS_DATA_DIR}" "${BIN_DIR}"; do
        p="${d}"; while [[ ! -d "${p}" && "${p}" != "/" ]]; do p="$(dirname "${p}")"; done
        libre=$(df -Pm "${p}" 2>/dev/null | awk 'NR==2 {print $4}'); libre=${libre:-0}
        local mini=500; [[ "${d}" == "${PROMETHEUS_DATA_DIR}" ]] && mini=5120
        (( libre >= mini )) && ok "Espace libre pour ${d} : ${libre} Mo" \
                            || ko "Espace insuffisant pour ${d} : ${libre} Mo (minimum ${mini} Mo)"
    done

    titre "Ports"
    local e nom port
    for e in "prometheus:${PROMETHEUS_PORT}" "alertmanager:${ALERTMANAGER_PORT}"; do
        nom="${e%%:*}"; port="${e##*:}"
        if port_utilise "${port}"; then
            if systemctl is-active --quiet "${nom}" 2>/dev/null; then warn "Port ${port} utilisé par ${nom} déjà installé"
            else ko "Port ${port} (${nom}) déjà utilisé par un autre programme"; fi
        else ok "Port ${port} (${nom}) libre"; fi
    done

    titre "Installation existante"
    if prometheus_installe || alertmanager_installe; then
        [[ -x "${BIN_DIR}/prometheus" ]] && log_info "$("${BIN_DIR}/prometheus" --version 2>&1 | head -n1)"
        [[ -x "${BIN_DIR}/alertmanager" ]] && log_info "$("${BIN_DIR}/alertmanager" --version 2>&1 | head -n1)"
        warn "Installation existante : '${SCRIPT_NAME} 01 --force' pour mettre à jour, '${SCRIPT_NAME} 99' pour repartir de zéro"
    else
        ok "Aucune installation précédente"
    fi

    titre "Archives"
    if [[ "${arch}" != "unsupported" ]]; then
        local comp ver f url
        for comp in prometheus alertmanager; do
            [[ "${comp}" == prometheus ]] && ver="${PROMETHEUS_VERSION}" || ver="${ALERTMANAGER_VERSION}"
            f="${comp}-${ver}.linux-${arch}.tar.gz"
            url="$(gh_url "prometheus/${comp}" "v${ver}" "${f}")"
            if [[ -f "${PACKAGES_DIR}/${f}" ]]; then
                tar -tzf "${PACKAGES_DIR}/${f}" >/dev/null 2>&1 && ok "Archive locale : packages/${f}" \
                                                              || ko "Archive corrompue : packages/${f}"
            elif [[ "${OFFLINE}" == "yes" ]]; then ko "Hors-ligne et archive absente : packages/${f}"
            elif url_ok "${url}"; then ok "Téléchargeable : ${f}"
            else ko "Archive inaccessible : ${url}"; fi
        done
    fi

    titre "Sécurité"
    cmd_exists getenforce && log_info "SELinux : $(getenforce 2>/dev/null)"
    if cmd_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then log_info "firewalld actif (OPEN_FIREWALL=${OPEN_FIREWALL})"
    elif cmd_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then log_info "ufw actif (OPEN_FIREWALL=${OPEN_FIREWALL})"
    else log_info "Aucun pare-feu firewalld/ufw actif"; fi

    titre "Bilan"
    if (( erreurs > 0 )); then
        log_error "${erreurs} erreur(s), ${avert} avertissement(s) : système NON prêt."
        return 1
    fi
    log_ok "0 erreur, ${avert} avertissement(s) : système prêt."
}

# =============================================================================
#  01 — INSTALLATION PROMETHEUS + ALERTMANAGER
# =============================================================================
etape_01() {
    local force=no checks=yes demarrer=yes agent_local=yes
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=yes ;; --skip-checks) checks=no ;;
            --no-start) demarrer=no ;; --sans-agent) agent_local=no ;;
            aide|-h|--help) cat <<EOF
01 — Installation de Prometheus et Alertmanager
  ${SCRIPT_NAME} 01 [--force] [--skip-checks] [--no-start] [--sans-agent]
    --force        met à jour une installation existante (configs sauvegardées)
    --skip-checks  n'exécute pas l'étape 00
    --no-start     n'active pas les services
    --sans-agent   n'installe pas l'agent Linux (node_exporter) sur ce serveur
EOF
                return 0 ;;
            *) die "Option inconnue : $1" ;;
        esac; shift
    done
    require_root
    titre "01 - Installation Prometheus ${PROMETHEUS_VERSION} / Alertmanager ${ALERTMANAGER_VERSION}"

    if [[ "${checks}" == yes ]]; then
        etape_00 || die "Vérifications en échec (corriger ou utiliser --skip-checks)"
    fi
    if [[ "${force}" != yes ]] && { [[ -e "${BIN_DIR}/prometheus" ]] || [[ -e "${BIN_DIR}/alertmanager" ]]; }; then
        die "Installation existante : utiliser --force pour mettre à jour, ou l'étape 99"
    fi

    titre "Archives"
    local arch pf af
    arch="$(detect_arch)"; [[ "${arch}" != unsupported ]] || die "Architecture non supportée"
    pf="prometheus-${PROMETHEUS_VERSION}.linux-${arch}.tar.gz"
    af="alertmanager-${ALERTMANAGER_VERSION}.linux-${arch}.tar.gz"
    local parch aarch
    parch="$(recuperer "$(gh_url prometheus/prometheus "v${PROMETHEUS_VERSION}" "${pf}")" "${pf}" \
             "$(gh_url prometheus/prometheus "v${PROMETHEUS_VERSION}" sha256sums.txt)")" || exit 1
    aarch="$(recuperer "$(gh_url prometheus/alertmanager "v${ALERTMANAGER_VERSION}" "${af}")" "${af}" \
             "$(gh_url prometheus/alertmanager "v${ALERTMANAGER_VERSION}" sha256sums.txt)")" || exit 1

    titre "Comptes et arborescence"
    creer_compte "${PROMETHEUS_USER}" "${PROMETHEUS_DATA_DIR}"
    creer_compte "${ALERTMANAGER_USER}" "${ALERTMANAGER_DATA_DIR}"
    install -d -m 0755 -o root -g "${PROMETHEUS_USER}" "${PROMETHEUS_CONF_DIR}" \
        "${PROMETHEUS_CONF_DIR}/rules" "${PROMETHEUS_CONF_DIR}/scrape.d" "${PROMETHEUS_CONF_DIR}/targets"
    install -d -m 0750 -o "${PROMETHEUS_USER}" -g "${PROMETHEUS_USER}" "${PROMETHEUS_DATA_DIR}"
    install -d -m 0755 -o root -g "${ALERTMANAGER_USER}" "${ALERTMANAGER_CONF_DIR}"
    install -d -m 0750 -o "${ALERTMANAGER_USER}" -g "${ALERTMANAGER_USER}" "${ALERTMANAGER_DATA_DIR}"
    log_ok "Arborescence prête"

    titre "Binaires"
    local s
    for s in prometheus alertmanager; do
        systemctl is-active --quiet "${s}" 2>/dev/null && systemctl stop "${s}"
    done
    extraire_binaire "${parch}" prometheus   "${BIN_DIR}/prometheus"
    extraire_binaire "${parch}" promtool     "${BIN_DIR}/promtool"
    extraire_binaire "${aarch}" alertmanager "${BIN_DIR}/alertmanager"
    extraire_binaire "${aarch}" amtool       "${BIN_DIR}/amtool"
    log_ok "$("${BIN_DIR}/prometheus" --version 2>&1 | head -n1)"
    log_ok "$("${BIN_DIR}/alertmanager" --version 2>&1 | head -n1)"

    titre "Configuration"
    local f
    for f in "${PROMETHEUS_CONF_DIR}/prometheus.yml" "${ALERTMANAGER_CONF_DIR}/alertmanager.yml"; do
        [[ -f "${f}" ]] && cp -p "${f}" "${f}.bak.$(date +%Y%m%d_%H%M%S)"
    done
    generer_prometheus_yml | ecrire_fichier "${PROMETHEUS_CONF_DIR}/prometheus.yml" "root:${PROMETHEUS_USER}" 0640 || exit 1
    deployer_regles
    valider_prometheus || die "Configuration Prometheus invalide"
    appliquer_alertmanager || die "Configuration Alertmanager invalide"
    log_ok "Configurations générées et validées"

    titre "Services"
    unite_prometheus   | ecrire_fichier "${SYSTEMD_DIR}/prometheus.service" root:root 0644 || exit 1
    unite_alertmanager | ecrire_fichier "${SYSTEMD_DIR}/alertmanager.service" root:root 0644 || exit 1
    restaurer_selinux "${BIN_DIR}" "${PROMETHEUS_CONF_DIR}" "${ALERTMANAGER_CONF_DIR}" \
        "${PROMETHEUS_DATA_DIR}" "${ALERTMANAGER_DATA_DIR}" "${SYSTEMD_DIR}"
    systemctl daemon-reload
    systemctl enable --quiet alertmanager prometheus
    ouvrir_port "${PROMETHEUS_PORT}" prometheus
    ouvrir_port "${ALERTMANAGER_PORT}" alertmanager

    if [[ "${demarrer}" == yes ]]; then
        systemctl restart alertmanager prometheus
        attendre_http "$(am_url)/-/ready" 30 && log_ok "Alertmanager prêt : $(am_url)" \
            || die "Alertmanager ne démarre pas : journalctl -u alertmanager"
        attendre_http "$(prom_url)/-/ready" 60 && log_ok "Prometheus prêt : $(prom_url)" \
            || die "Prometheus ne démarre pas : journalctl -u prometheus"
    fi

    if [[ "${agent_local}" == yes ]]; then
        titre "Agent Linux local"
        agent_installer linux && cible_ajouter linux "$(cible_locale 9100)" "role=supervision"
    fi

    titre "Installation terminée"
    cat <<EOF
  Prometheus   : http://$(nom_hote):${PROMETHEUS_PORT}
  Alertmanager : http://$(nom_hote):${ALERTMANAGER_PORT}

  Étapes suivantes :
    ${SCRIPT_NAME} 03 catalogue           applications supervisables
    ${SCRIPT_NAME} 03 cible <app> <hôte:port>
    ${SCRIPT_NAME} 04 ajouter <canal>      Slack, Teams, Telegram, e-mail...
    ${SCRIPT_NAME} 05                      Grafana + tableau de bord
EOF
}

# =============================================================================
#  02 — CONFIGURATION (paramètres, seuils)
# =============================================================================
etape_02() {
    local action="${1:-afficher}"; shift || true
    case "${action}" in
    afficher)
        titre "Paramètres (section CONFIGURATION de ${SCRIPT_NAME})"
        local ligne var
        while IFS= read -r ligne; do
            if [[ "${ligne}" =~ ^#\ ---\ (.*)\ -+$ ]]; then
                printf '\n %s%s%s\n' "${C_GRAS}" "${BASH_REMATCH[1]}" "${C_0}"
            elif [[ "${ligne}" =~ ^:\ \"\$\{([A-Z0-9_]+):= ]]; then
                var="${BASH_REMATCH[1]}"
                local v="${!var}"
                [[ "${var}" == *PASSWORD* && -n "${v}" ]] && v="********"
                printf '   %-32s %s\n' "${var}" "${v}"
            fi
        done < <(sed -n '/^#  CONFIGURATION$/,/^#  FIN DE LA CONFIGURATION/p' "${SCRIPT_PATH}")
        echo
        echo " Modifier : ${SCRIPT_NAME} 02 definir <VARIABLE> <valeur>"
        ;;
    definir)
        [[ $# -ge 2 ]] || die "Usage : ${SCRIPT_NAME} 02 definir <VARIABLE> <valeur>"
        require_root
        definir_parametre "$1" "$2"
        if prometheus_installe; then
            confirm "Appliquer maintenant la configuration ?" && etape_02 appliquer
        fi
        ;;
    appliquer)
        require_root
        prometheus_installe || die "Prometheus n'est pas installé (étape 01)"
        titre "02 - Application de la configuration"
        local u avant
        cp -p "${PROMETHEUS_CONF_DIR}/prometheus.yml" "$(workdir)/prometheus.yml.prec"
        generer_prometheus_yml | ecrire_fichier "${PROMETHEUS_CONF_DIR}/prometheus.yml" "root:${PROMETHEUS_USER}" 0640 || exit 1
        deployer_regles
        if ! valider_prometheus; then
            cp -p "$(workdir)/prometheus.yml.prec" "${PROMETHEUS_CONF_DIR}/prometheus.yml"
            die "Configuration invalide : version précédente restaurée"
        fi
        appliquer_alertmanager || true
        for u in prometheus alertmanager; do
            avant="$(cat "${SYSTEMD_DIR}/${u}.service" 2>/dev/null)"
            "unite_${u}" | ecrire_fichier "${SYSTEMD_DIR}/${u}.service" root:root 0644 || exit 1
            if [[ "${avant}" != "$(cat "${SYSTEMD_DIR}/${u}.service")" ]]; then
                systemctl daemon-reload
                systemctl restart "${u}" && log_ok "${u} redémarré (paramètres de service modifiés)"
            fi
        done
        recharger_prometheus
        ;;
    regles)
        titre "Règles d'alerte"
        if [[ -n "${1:-}" ]]; then
            catalogue "$1" && regles_lister "${APP_REGLES}" || regles_lister "$1"
        else
            regles_lister "${REGLES_FICHIERS[@]}"
        fi
        echo
        ;;
    aide|*) cat <<EOF
02 — Configuration
  ${SCRIPT_NAME} 02 afficher                     paramètres et seuils actuels
  ${SCRIPT_NAME} 02 definir <VARIABLE> <valeur>  modifie le script et propose d'appliquer
  ${SCRIPT_NAME} 02 appliquer                    régénère configurations, règles et services
  ${SCRIPT_NAME} 02 regles [application]         liste des règles d'alerte
Exemple : ${SCRIPT_NAME} 02 definir SEUIL_DISQUE_WARN 75
EOF
        ;;
    esac
}

# =============================================================================
#  03 — AGENTS ET APPLICATIONS
# =============================================================================

# Adresse de la cible pour un agent installé sur ce serveur
cible_locale() {
    local h; h="$(nom_hote)"
    if getent hosts "${h}" >/dev/null 2>&1; then echo "${h}:$1"; else echo "127.0.0.1:$1"; fi
}

# Prépare la configuration propre à chaque agent.
# Renseigne AG_ARGS (arguments), AG_ENV (variables d'environnement),
# AG_USER, AG_CAPS (capacités systemd) et AG_NOTE (consignes).
agent_configurer() {
    local app="$1" dir="$2"
    AG_ARGS="--web.listen-address=:${APP_PORT}"; AG_ENV=""; AG_USER="${EXPORTER_USER}"
    AG_CAPS=""; AG_NOTE=""
    case "${app}" in
    linux)
        install -d -m 0755 -o "${EXPORTER_USER}" -g "${EXPORTER_USER}" /var/lib/node_exporter/textfile
        AG_ARGS+=" --collector.systemd --collector.processes --collector.textfile.directory=/var/lib/node_exporter/textfile"
        AG_NOTE="Métriques personnalisées possibles via des fichiers *.prom dans /var/lib/node_exporter/textfile" ;;
    http|tcp|icmp)
        APP_PORT=9115; AG_ARGS="--web.listen-address=:9115 --config.file=${dir}/blackbox.yml"
        AG_CAPS="AmbientCapabilities=CAP_NET_RAW"
        ecrire_fichier "${dir}/blackbox.yml" "root:${EXPORTER_USER}" 0640 <<'EOF'
# Modules de sonde du blackbox_exporter (Prometheus-bundle)
modules:
  http_2xx:            # page web : code 2xx attendu, redirections suivies
    prober: http
    timeout: 10s
    http:
      preferred_ip_protocol: ip4
      follow_redirects: true
  http_post_2xx:       # API en POST
    prober: http
    timeout: 10s
    http:
      method: POST
      preferred_ip_protocol: ip4
  tcp_connect:         # ouverture d'un port TCP
    prober: tcp
    timeout: 5s
    tcp:
      preferred_ip_protocol: ip4
  icmp:                # ping
    prober: icmp
    timeout: 5s
    icmp:
      preferred_ip_protocol: ip4
EOF
        ;;
    mysql)
        demander MYSQL_HOTE "Adresse MySQL (hôte:port)" "127.0.0.1:3306"
        demander MYSQL_UTILISATEUR "Utilisateur de supervision" "exporter"
        demander MYSQL_MOT_DE_PASSE "Mot de passe de ${MYSQL_UTILISATEUR}" "" secret
        ecrire_fichier "${dir}/my.cnf" "root:${EXPORTER_USER}" 0640 <<EOF
[client]
user=${MYSQL_UTILISATEUR}
password=${MYSQL_MOT_DE_PASSE}
host=${MYSQL_HOTE%%:*}
port=${MYSQL_HOTE##*:}
EOF
        AG_ARGS+=" --config.my-cnf=${dir}/my.cnf"
        AG_NOTE="Compte à créer dans MySQL :
  CREATE USER '${MYSQL_UTILISATEUR}'@'localhost' IDENTIFIED BY '********' WITH MAX_USER_CONNECTIONS 3;
  GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO '${MYSQL_UTILISATEUR}'@'localhost';" ;;
    postgresql)
        demander PG_HOTE "Adresse PostgreSQL (hôte:port)" "127.0.0.1:5432"
        demander PG_UTILISATEUR "Utilisateur de supervision" "exporter"
        demander PG_MOT_DE_PASSE "Mot de passe de ${PG_UTILISATEUR}" "" secret
        demander PG_SSLMODE "Mode SSL (disable, require, verify-full)" "disable"
        AG_ENV="DATA_SOURCE_NAME=postgresql://${PG_UTILISATEUR}:${PG_MOT_DE_PASSE}@${PG_HOTE}/postgres?sslmode=${PG_SSLMODE}"
        AG_NOTE="Compte à créer dans PostgreSQL :
  CREATE USER ${PG_UTILISATEUR} WITH PASSWORD '********';
  GRANT pg_monitor TO ${PG_UTILISATEUR};
(caractères spéciaux du mot de passe à encoder façon URL : @ -> %40, : -> %3A)" ;;
    redis)
        demander REDIS_HOTE "Adresse Redis (hôte:port)" "127.0.0.1:6379"
        demander REDIS_MOT_DE_PASSE "Mot de passe Redis (laisser '-' si aucun)" "-" secret
        AG_ENV="REDIS_ADDR=redis://${REDIS_HOTE}"
        [[ "${REDIS_MOT_DE_PASSE}" != "-" ]] && AG_ENV+=$'\n'"REDIS_PASSWORD=${REDIS_MOT_DE_PASSE}" ;;
    mongodb)
        demander MONGODB_URI_SUPERVISION "URI MongoDB" "mongodb://127.0.0.1:27017/admin"
        AG_ENV="MONGODB_URI=${MONGODB_URI_SUPERVISION}"
        AG_ARGS+=" --collect-all --compatible-mode"
        AG_NOTE="Rôle MongoDB conseillé pour l'utilisateur : clusterMonitor + read sur local." ;;
    memcached)
        demander MEMCACHED_HOTE "Adresse Memcached (hôte:port)" "127.0.0.1:11211"
        AG_ARGS+=" --memcached.address=${MEMCACHED_HOTE}" ;;
    elasticsearch)
        demander ES_URL "URL Elasticsearch" "http://127.0.0.1:9200"
        demander ES_UTILISATEUR_SUPERVISION "Utilisateur (laisser '-' si aucun)" "-"
        AG_ARGS+=" --es.uri=${ES_URL} --es.all --es.indices"
        if [[ "${ES_UTILISATEUR_SUPERVISION}" != "-" ]]; then
            demander ES_MOT_DE_PASSE "Mot de passe Elasticsearch" "" secret
            AG_ENV="ES_USERNAME=${ES_UTILISATEUR_SUPERVISION}"$'\n'"ES_PASSWORD=${ES_MOT_DE_PASSE}"
        fi
        AG_NOTE="Rôle conseillé : privilège cluster 'monitor' + index 'monitor' sur *." ;;
    nginx)
        demander NGINX_STATUS_URL "URL de la page stub_status" "http://127.0.0.1:8080/stub_status"
        AG_ARGS+=" --nginx.scrape-uri=${NGINX_STATUS_URL}"
        AG_NOTE="Bloc à ajouter dans Nginx (puis nginx -t && systemctl reload nginx) :
  server {
      listen 127.0.0.1:8080;
      location = /stub_status { stub_status; allow 127.0.0.1; deny all; }
  }" ;;
    apache)
        demander APACHE_STATUS_URL "URL de la page server-status" "http://127.0.0.1/server-status?auto"
        AG_ARGS+=" --scrape_uri=${APACHE_STATUS_URL}"
        AG_NOTE="Activer mod_status : <Location /server-status> SetHandler server-status ; Require local </Location>" ;;
    phpfpm)
        demander PHPFPM_STATUS "Adresse de statut PHP-FPM" "tcp://127.0.0.1:9000/status"
        AG_ARGS="server --web.listen-address=:${APP_PORT} --phpfpm.scrape-uri=${PHPFPM_STATUS}"
        AG_USER="root"
        AG_NOTE="Dans le pool PHP-FPM (www.conf) : pm.status_path = /status (puis redémarrer php-fpm).
Pour une socket : unix:///run/php/php-fpm.sock;/status" ;;
    kafka)
        demander KAFKA_BROKERS "Brokers Kafka (séparés par des virgules)" "127.0.0.1:9092"
        local b; IFS=',' read -ra _brokers <<<"${KAFKA_BROKERS}"
        for b in "${_brokers[@]}"; do AG_ARGS+=" --kafka.server=${b// /}"; done ;;
    process)
        demander PROCESSUS_NOMS "Noms des processus à surveiller (ex. java,nginx,postgres)" ""
        local p liste=""
        IFS=',' read -ra _procs <<<"${PROCESSUS_NOMS}"
        for p in "${_procs[@]}"; do liste+="      - \"${p// /}\""$'\n'; done
        ecrire_fichier "${dir}/process.yml" "root:${EXPORTER_USER}" 0640 <<EOF
# Processus surveillés (nom de commande exact, voir : ps -eo comm)
process_names:
  - name: "{{.Comm}}"
    comm:
${liste}
EOF
        AG_ARGS+=" --config.path=${dir}/process.yml"
        AG_USER="root"
        AG_NOTE="Liste modifiable dans ${dir}/process.yml puis : systemctl restart process-exporter
Important : un processus n'est suivi qu'après avoir été vu au moins une fois en fonctionnement.
Vérifier qu'il apparaît : curl -s localhost:${APP_PORT}/metrics | grep num_procs" ;;
    esac
}

# Consignes pour les applications sans agent Linux à installer
agent_instructions() {
    local app="$1"
    case "${app}" in
    windows) cat <<EOF
Sur le serveur Windows (PowerShell administrateur) :
  Invoke-WebRequest -Uri ${GITHUB_URL}/prometheus-community/windows_exporter/releases/download/v${WINDOWS_EXPORTER_VERSION}/windows_exporter-${WINDOWS_EXPORTER_VERSION}-amd64.msi -OutFile windows_exporter.msi
  msiexec /i windows_exporter.msi ENABLED_COLLECTORS="cpu,logical_disk,memory,net,os,service,system" LISTEN_PORT=9182
  New-NetFirewallRule -DisplayName "windows_exporter" -Direction Inbound -Protocol TCP -LocalPort 9182 -Action Allow
Puis ici : ${SCRIPT_NAME} 03 cible windows <serveur>:9182
EOF
    ;;
    haproxy) cat <<'EOF'
Ajouter dans /etc/haproxy/haproxy.cfg (HAProxy 2.4+), puis : haproxy -c -f /etc/haproxy/haproxy.cfg && systemctl reload haproxy
  frontend prometheus
      bind *:8405
      mode http
      http-request use-service prometheus-exporter if { path /metrics }
      no log
EOF
    ;;
    rabbitmq) cat <<'EOF'
Sur chaque nœud RabbitMQ :
  rabbitmq-plugins enable rabbitmq_prometheus
Les métriques sont exposées sur le port 15692 (/metrics).
EOF
    ;;
    springboot) cat <<'EOF'
Dans l'application Spring Boot :
  - dépendance : io.micrometer:micrometer-registry-prometheus
  - application.properties :
      management.endpoints.web.exposure.include=health,info,prometheus
      management.metrics.tags.application=${spring.application.name}
Les métriques sont exposées sur /actuator/prometheus (port de l'application).
EOF
    ;;
    docker) cat <<EOF
Sur l'hôte Docker :
  docker run -d --name=cadvisor --restart=always -p 8080:8080 \\
    -v /:/rootfs:ro -v /var/run:/var/run:ro -v /sys:/sys:ro \\
    -v /var/lib/docker/:/var/lib/docker:ro -v /dev/disk/:/dev/disk:ro \\
    --privileged --device=/dev/kmsg gcr.io/cadvisor/cadvisor:v${CADVISOR_VERSION}
EOF
    ;;
    application) cat <<'EOF'
L'application doit exposer ses métriques au format Prometheus (/metrics) :
  Java : Micrometer | Go : prometheus/client_golang | Python : prometheus_client
  Node.js : prom-client | .NET : prometheus-net | PHP : promphp/prometheus_client_php
Chemin différent de /metrics : ajouter le libellé chemin=/mon/chemin à la cible.
Les règles 'application' s'appliquent aux métriques standard http_requests_total
et process_* de ces bibliothèques.
EOF
    ;;
    esac
}

# --- Installation d'un agent sur CE serveur ----------------------------------
agent_installer() {
    local app="$1"
    catalogue "${app}" || die "Application inconnue : ${app} (voir : ${SCRIPT_NAME} 03 catalogue)"
    require_root
    case "${APP_AGENT}" in
        natif|externe)
            titre "Application ${app} : pas d'agent Linux à installer"
            agent_instructions "${app}"
            return 0 ;;
        jmx) agent_installer_jmx; return $? ;;
    esac

    titre "Installation de l'agent ${APP_BIN} (${app})"
    local dir="${EXPORTERS_CONF_DIR}/${APP_BIN}" archive unit
    creer_compte "${EXPORTER_USER}" /nonexistent
    install -d -m 0750 -o root -g "${EXPORTER_USER}" "${dir}"
    agent_configurer "${app}" "${dir}"
    archive="$(recuperer "${APP_URL}" "$(basename "${APP_URL}")" ${APP_SUMS})" || exit 1
    systemctl is-active --quiet "${APP_BIN}" 2>/dev/null && systemctl stop "${APP_BIN}"
    extraire_binaire "${archive}" "${APP_BIN}" "${BIN_DIR}/${APP_BIN}"
    if [[ -n "${AG_ENV}" ]]; then
        printf '%s\n' "${AG_ENV}" | ecrire_fichier "${dir}/${APP_BIN}.env" "root:root" 0600 || exit 1
    fi
    unit="${SYSTEMD_DIR}/${APP_BIN}.service"
    ecrire_fichier "${unit}" root:root 0644 <<EOF
# ${MARQUEUR} — agent ${app}
[Unit]
Description=Agent Prometheus ${APP_BIN} (${app})
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${AG_USER}
Group=${AG_USER}
EnvironmentFile=-${dir}/${APP_BIN}.env
ExecStart=${BIN_DIR}/${APP_BIN} ${AG_ARGS}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=read-only
${AG_CAPS}

[Install]
WantedBy=multi-user.target
EOF
    restaurer_selinux "${BIN_DIR}/${APP_BIN}" "${dir}" "${unit}"
    systemctl daemon-reload
    systemctl enable --quiet "${APP_BIN}"
    systemctl restart "${APP_BIN}"
    ouvrir_port "${APP_PORT}" "${APP_BIN}"
    if attendre_http "http://127.0.0.1:${APP_PORT}/metrics" 20; then
        log_ok "Agent ${APP_BIN} actif : http://$(nom_hote):${APP_PORT}/metrics"
    else
        log_error "L'agent ne répond pas : journalctl -u ${APP_BIN}"
        return 1
    fi
    if [[ -n "${AG_NOTE}" ]]; then
        echo; echo "${C_Y}À faire côté application :${C_0}"; echo "${AG_NOTE}"; echo
    fi
}

agent_installer_jmx() {
    titre "Installation de l'agent Java JMX"
    install -d -m 0755 "${JMX_DIR}"
    local jar
    jar="$(recuperer "${APP_URL}" "$(basename "${APP_URL}")" ${APP_SUMS})" || exit 1
    install -m 0644 "${jar}" "${JMX_DIR}/jmx_prometheus_javaagent.jar"
    ecrire_fichier "${JMX_DIR}/config.yaml" root:root 0644 <<'EOF'
# Agent JMX Prometheus — Géré par prometheus-bundle
# Expose les métriques JVM (mémoire, GC, threads) et tous les MBeans.
lowercaseOutputName: true
lowercaseOutputLabelNames: true
rules:
  - pattern: ".*"
EOF
    log_ok "Agent installé : ${JMX_DIR}/jmx_prometheus_javaagent.jar"
    cat <<EOF

${C_Y}À faire : ajouter l'option suivante au lancement de la JVM puis la redémarrer${C_0}
  -javaagent:${JMX_DIR}/jmx_prometheus_javaagent.jar=${APP_PORT}:${JMX_DIR}/config.yaml

  Tomcat   : dans bin/setenv.sh  ->  CATALINA_OPTS="\$CATALINA_OPTS -javaagent:..."
  WildFly  : dans bin/standalone.conf  ->  JAVA_OPTS="\$JAVA_OPTS -javaagent:..."
  systemd  : Environment="JAVA_TOOL_OPTIONS=-javaagent:..." (systemctl edit <service>)
  Plusieurs JVM sur un même serveur : un port différent par JVM (9404, 9405...).
Puis : ${SCRIPT_NAME} 03 cible jvm <serveur>:${APP_PORT}
EOF
}

agent_desinstaller() {
    local app="$1"
    catalogue "${app}" || die "Application inconnue : ${app}"
    require_root
    if [[ "${APP_AGENT}" == jmx ]]; then
        rm -rf "${JMX_DIR}" && log_ok "Agent JMX supprimé (retirer -javaagent des JVM)"
        return 0
    fi
    [[ "${APP_AGENT}" == exporter ]] || { log_info "Aucun agent Linux pour ${app}"; return 0; }
    local unit="${SYSTEMD_DIR}/${APP_BIN}.service"
    if [[ -f "${unit}" ]]; then
        systemctl disable --now --quiet "${APP_BIN}" 2>/dev/null || true
        rm -f "${unit}"; systemctl daemon-reload
    fi
    rm -f "${BIN_DIR}/${APP_BIN}"
    rm -rf "${EXPORTERS_CONF_DIR:?}/${APP_BIN}"
    [[ "${APP_BIN}" == blackbox_exporter ]] && APP_PORT=9115
    [[ -n "${APP_PORT}" ]] && fermer_port "${APP_PORT}"
    log_ok "Agent ${APP_BIN} désinstallé"
}

# --- Déclaration des cibles dans Prometheus ----------------------------------
scrape_job() {
    local app="$1" module=""
    catalogue "${app}"
    case "${app}" in http) module=http_2xx ;; tcp) module=tcp_connect ;; icmp) module=icmp ;; esac
    echo "# ${MARQUEUR} — ${APP_NOM}"
    echo "scrape_configs:"
    echo "  - job_name: \"${app}\""
    if [[ -n "${module}" ]]; then
        cat <<EOF
    metrics_path: /probe
    params:
      module: [${module}]
    file_sd_configs:
      - files: ["${PROMETHEUS_CONF_DIR}/targets/${app}.yml"]
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: "${BLACKBOX_ADDRESS}"
EOF
    else
        cat <<EOF
    metrics_path: "${APP_METRICS_PATH}"
    file_sd_configs:
      - files: ["${PROMETHEUS_CONF_DIR}/targets/${app}.yml"]
EOF
    fi
}

# Convertit "env=prod,equipe=web" en libellés YAML ; chemin= et schema= sont
# traduits en __metrics_path__ et __scheme__
libelles_yaml() {
    local entree="$1" k v sortie="" kv
    [[ -z "${entree}" ]] && { echo "{}"; return; }
    IFS=',' read -ra _kv <<<"${entree}"
    for kv in "${_kv[@]}"; do
        k="${kv%%=*}"; v="${kv#*=}"
        [[ "${kv}" == *=* && -n "${k}" ]] || die "Libellé invalide : ${kv} (format clé=valeur)"
        case "${k}" in chemin) k="__metrics_path__" ;; schema) k="__scheme__" ;; esac
        [[ "${k}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die "Nom de libellé invalide : ${k}"
        sortie+="${sortie:+, }\"${k}\": \"${v//\"/}\""
    done
    echo "{${sortie}}"
}

cible_ajouter() {
    local app="$1" cible="${2:-}" libelles="${3:-}"
    catalogue "${app}" || die "Application inconnue : ${app}"
    require_root
    prometheus_installe || die "Prometheus n'est pas installé sur ce serveur (étape 01)"
    [[ -n "${cible}" ]] || die "Usage : ${SCRIPT_NAME} 03 cible ${app} <adresse> [clé=valeur,...]"
    case "${app}" in
        http) [[ "${cible}" =~ ^https?:// ]] || cible="https://${cible}" ;;
        icmp) ;;
        *) [[ "${cible}" == *:* ]] || { [[ -n "${APP_PORT}" ]] && cible="${cible}:${APP_PORT}" || die "Port requis : ${cible}:<port>"; } ;;
    esac
    [[ "${cible}" != *'"'* && "${cible}" != *' '* ]] || die "Adresse invalide : ${cible}"

    # Sonde : blackbox local installé automatiquement si nécessaire
    if [[ "${app}" =~ ^(http|tcp|icmp)$ && "${BLACKBOX_ADDRESS}" =~ ^(127\.0\.0\.1|localhost): \
          && ! -f "${SYSTEMD_DIR}/blackbox_exporter.service" ]]; then
        log_info "Sonde blackbox absente : installation locale"
        agent_installer "${app}" || die "Installation du blackbox_exporter impossible"
        catalogue "${app}"
    fi

    local tf="${PROMETHEUS_CONF_DIR}/targets/${app}.yml" sf="${PROMETHEUS_CONF_DIR}/scrape.d/${app}.yml"
    install -d -m 0755 -o root -g "${PROMETHEUS_USER}" "${PROMETHEUS_CONF_DIR}/targets" "${PROMETHEUS_CONF_DIR}/scrape.d"
    if [[ -f "${tf}" ]] && grep -qF -- "- targets: [\"${cible}\"]" "${tf}"; then
        log_warn "Cible déjà déclarée : ${cible} — libellés mis à jour"
        cible_retirer "${app}" "${cible}" silencieux
    fi
    [[ -f "${tf}" ]] || echo "# ${MARQUEUR} — cibles ${app}" | ecrire_fichier "${tf}" "root:${PROMETHEUS_USER}" 0644
    printf -- '- targets: ["%s"]\n  labels: %s\n' "${cible}" "$(libelles_yaml "${libelles}")" >> "${tf}"
    if [[ ! -f "${sf}" ]]; then
        scrape_job "${app}" | ecrire_fichier "${sf}" "root:${PROMETHEUS_USER}" 0644 || exit 1
        deployer_regles
        if ! valider_prometheus; then
            rm -f "${sf}"; deployer_regles
            die "Configuration invalide : job ${app} annulé"
        fi
        recharger_prometheus
    fi
    log_ok "Cible ajoutée : ${app} → ${cible}"
    if [[ "${APP_AGENT}" =~ ^(natif|externe)$ ]]; then echo; agent_instructions "${app}"; fi
    return 0
}

cible_retirer() {
    local app="$1" cible="${2:-}" mode="${3:-}"
    local tf="${PROMETHEUS_CONF_DIR}/targets/${app}.yml"
    [[ -n "${cible}" ]] || die "Usage : ${SCRIPT_NAME} 03 retirer <application> <adresse>"
    [[ -f "${tf}" ]] || die "Aucune cible pour ${app}"
    [[ "${app}" == http && ! "${cible}" =~ ^https?:// ]] && cible="https://${cible}"
    if [[ "${app}" != http && "${app}" != icmp && "${cible}" != *:* ]] && catalogue "${app}" && [[ -n "${APP_PORT}" ]]; then
        cible="${cible}:${APP_PORT}"
    fi
    grep -qF -- "- targets: [\"${cible}\"]" "${tf}" || die "Cible introuvable : ${cible}"
    awk -v l="- targets: [\"${cible}\"]" '$0 == l {saut=1; next} saut && /^  labels:/ {saut=0; next} {saut=0; print}' "${tf}" \
        | ecrire_fichier "${tf}" "root:${PROMETHEUS_USER}" 0644 || exit 1
    [[ "${mode}" == silencieux ]] && return 0
    log_ok "Cible retirée : ${app} → ${cible}"
    if ! grep -q -- '- targets:' "${tf}"; then
        rm -f "${tf}" "${PROMETHEUS_CONF_DIR}/scrape.d/${app}.yml"
        deployer_regles
        recharger_prometheus
        log_info "Plus aucune cible ${app} : job et règles retirés"
    fi
}

cibles_lister() {
    titre "Applications supervisées"
    local app tf etat
    local etats=""
    if prometheus_installe && cmd_exists curl; then
        etats="$("${BIN_DIR}/promtool" query instant "$(prom_url)" 'up' 2>/dev/null)"
    fi
    for app in $(applications_actives); do
        tf="${PROMETHEUS_CONF_DIR}/targets/${app}.yml"
        catalogue "${app}" 2>/dev/null
        printf '\n %s%s%s — %s\n' "${C_GRAS}" "${app}" "${C_0}" "${APP_NOM:-}"
        grep -- '- targets:' "${tf}" 2>/dev/null | sed 's/.*\["\(.*\)"\].*/\1/' | while read -r c; do
            etat="?"
            if [[ -n "${etats}" ]]; then
                local ligne; ligne="$(grep -F "instance=\"${c}\"" <<<"${etats}" | grep -F "job=\"${app}\"" | head -n1)"
                case "${ligne}" in *"=> 1 "*) etat="${C_G}EN LIGNE${C_0}" ;; *"=> 0 "*) etat="${C_R}EN PANNE${C_0}" ;; esac
                if [[ "${app}" =~ ^(http|tcp|icmp)$ ]]; then
                    local ps; ps="$("${BIN_DIR}/promtool" query instant "$(prom_url)" "probe_success{instance=\"${c}\"}" 2>/dev/null)"
                    case "${ps}" in *"=> 1 "*) etat="${C_G}OK${C_0}" ;; *"=> 0 "*) etat="${C_R}ÉCHEC${C_0}" ;; esac
                fi
            fi
            printf '   %-45s %s\n' "${c}" "${etat}"
        done
    done
    echo
}

# Installe l'agent sur un serveur distant via SSH, puis déclare la cible
agent_deployer() {
    local app="$1" dest="${2:-}" hote port
    [[ -n "${dest}" ]] || die "Usage : ${SCRIPT_NAME} 03 deployer <application> <utilisateur@serveur> [clé=valeur,...]"
    catalogue "${app}" || die "Application inconnue : ${app}"
    [[ "${APP_AGENT}" == exporter || "${APP_AGENT}" == jmx ]] || die "Pas d'agent Linux à déployer pour ${app}"
    cmd_exists ssh && cmd_exists scp || die "ssh et scp sont requis"
    hote="${dest#*@}"; port="${APP_PORT}"
    titre "Déploiement de l'agent ${app} sur ${dest}"
    scp -q "${SCRIPT_PATH}" "${dest}:/tmp/${SCRIPT_NAME}" || die "Copie SSH impossible vers ${dest}"
    ssh -t "${dest}" "sudo OPEN_FIREWALL=${OPEN_FIREWALL} bash /tmp/${SCRIPT_NAME} 03 agent ${app}; r=\$?; rm -f /tmp/${SCRIPT_NAME}; exit \$r" \
        || die "Installation distante en échec"
    [[ "${APP_AGENT}" == jmx ]] && { log_warn "Ajouter -javaagent à la JVM, puis : ${SCRIPT_NAME} 03 cible jvm ${hote}:${port}"; return 0; }
    if [[ -z "${port}" ]]; then
        log_info "Sonde installée sur ${hote} : pour l'utiliser, définir BLACKBOX_ADDRESS=${hote}:9115 (02 definir)"
    elif prometheus_installe; then
        cible_ajouter "${app}" "${hote}:${port}" "${3:-}"
    fi
}

menu_applications() {
    local i=1 app
    for app in "${APPLICATIONS[@]}"; do
        catalogue "${app}"; printf '  %2d) %-14s %s\n' "${i}" "${app}" "${APP_NOM}"; i=$((i + 1))
    done
    local choix; read -r -p "Application (numéro ou nom) : " choix
    [[ "${choix}" =~ ^[0-9]+$ ]] && choix="${APPLICATIONS[$((choix - 1))]:-}"
    app_valide "${choix}" || die "Choix invalide"
    MENU_APP="${choix}"
}

etape_03() {
    local action="${1:-}"; shift || true
    case "${action}" in
        catalogue) afficher_catalogue ;;
        agent)     [[ -n "${1:-}" ]] || { menu_applications; set -- "${MENU_APP}"; }
                   agent_installer "$1" ;;
        desinstaller) [[ -n "${1:-}" ]] || die "Usage : ${SCRIPT_NAME} 03 desinstaller <application>"
                   agent_desinstaller "$1" ;;
        deployer)  agent_deployer "$@" ;;
        cible)     if [[ -z "${1:-}" ]]; then
                       menu_applications; local c l
                       read -r -p "Adresse (hôte:port, URL pour http) : " c
                       read -r -p "Libellés optionnels (ex. env=prod,equipe=web) : " l
                       set -- "${MENU_APP}" "${c}" "${l}"
                   fi
                   cible_ajouter "$@" ;;
        retirer)   cible_retirer "$@" ;;
        liste)     cibles_lister ;;
        regles)    etape_02 regles "$@" ;;
        *) cat <<EOF
03 — Agents et applications
  ${SCRIPT_NAME} 03 catalogue                           applications supervisables
  ${SCRIPT_NAME} 03 agent <app>                         installe l'agent sur CE serveur
  ${SCRIPT_NAME} 03 deployer <app> <user@serveur> [lib] installe l'agent à distance (SSH) + déclare la cible
  ${SCRIPT_NAME} 03 cible <app> <adresse> [lib]         déclare une cible dans Prometheus
  ${SCRIPT_NAME} 03 retirer <app> <adresse>             retire une cible
  ${SCRIPT_NAME} 03 liste                               cibles déclarées et leur état
  ${SCRIPT_NAME} 03 desinstaller <app>                  supprime l'agent de CE serveur
  ${SCRIPT_NAME} 03 regles [app]                        règles d'alerte associées
Libellés [lib] : env=prod,equipe=web (chemin=/x et schema=https changent l'URL collectée)
Exemples :
  ${SCRIPT_NAME} 03 cible http https://www.exemple.fr env=prod
  ${SCRIPT_NAME} 03 deployer mysql admin@bdd01 env=prod
  ${SCRIPT_NAME} 03 cible springboot app01:8080 env=recette
EOF
        ;;
    esac
}

# =============================================================================
#  04 — CANAUX D'ALERTE
# =============================================================================
CANAUX=(email slack teams telegram discord mattermost rocketchat webex
        pagerduty opsgenie pushover sms jira webhook)

canal_description() {
    case "$1" in
        email)      echo "E-mail (SMTP : Exchange, Office 365, Gmail, relais interne)" ;;
        slack)      echo "Slack (webhook entrant)" ;;
        teams)      echo "Microsoft Teams (workflow Power Automate « webhook »)" ;;
        telegram)   echo "Telegram (bot + identifiant de conversation)" ;;
        discord)    echo "Discord (webhook de salon)" ;;
        mattermost) echo "Mattermost (webhook entrant)" ;;
        rocketchat) echo "Rocket.Chat (webhook entrant)" ;;
        webex)      echo "Cisco Webex (bot + salle)" ;;
        pagerduty)  echo "PagerDuty (astreinte, escalade, appel téléphonique)" ;;
        opsgenie)   echo "Opsgenie / Jira Service Management (astreinte)" ;;
        pushover)   echo "Pushover (notification push sur mobile)" ;;
        sms)        echo "SMS via Amazon SNS" ;;
        jira)       echo "Jira (création automatique de tickets)" ;;
        webhook)    echo "Webhook générique (ITSM, GLPI, ServiceNow, n8n, script maison...)" ;;
        *) return 1 ;;
    esac
}

# Chaîne YAML entre guillemets doubles, échappée
yq() { local v="${1//\\/\\\\}"; v="${v//\"/\\\"}"; printf '"%s"' "${v}"; }

# canal_yaml <type> <nom> : pose les questions et produit le récepteur
canal_yaml() {
    local type="$1" nom="$2"
    echo "  - name: \"${nom}\""
    case "${type}" in
    email)
        demander EMAIL_DESTINATAIRES "Destinataire(s), séparés par des virgules" ""
        demander EMAIL_EXPEDITEUR "Adresse d'expédition" "alertes@$(hostname -d 2>/dev/null || echo localdomain)"
        demander EMAIL_SMTP "Serveur SMTP (hôte:port)" "localhost:25"
        demander EMAIL_UTILISATEUR "Utilisateur SMTP (laisser '-' si aucun)" "-"
        [[ "${EMAIL_UTILISATEUR}" != "-" ]] && demander EMAIL_MOT_DE_PASSE "Mot de passe SMTP" "" secret
        demander EMAIL_TLS "Exiger STARTTLS (oui/non)" "non"
        cat <<EOF
    email_configs:
      - to: $(yq "${EMAIL_DESTINATAIRES}")
        from: $(yq "${EMAIL_EXPEDITEUR}")
        smarthost: $(yq "${EMAIL_SMTP}")
        require_tls: $([[ "${EMAIL_TLS}" =~ ^(o|oui|y|yes)$ ]] && echo true || echo false)
        send_resolved: true
        headers:
          Subject: '{{ template "fr.titre" . }}'
        html: '{{ template "fr.email" . }}'
EOF
        if [[ "${EMAIL_UTILISATEUR}" != "-" ]]; then
            echo "        auth_username: $(yq "${EMAIL_UTILISATEUR}")"
            echo "        auth_password: $(yq "${EMAIL_MOT_DE_PASSE}")"
        fi ;;
    slack|mattermost|rocketchat)
        demander CANAL_WEBHOOK_URL "URL du webhook entrant" ""
        demander CANAL_SALON "Salon (ex. #alertes, laisser '-' pour celui du webhook)" "-"
        cat <<EOF
    slack_configs:
      - api_url: $(yq "${CANAL_WEBHOOK_URL}")
        send_resolved: true
        title: '{{ template "fr.titre" . }}'
        text: '{{ template "fr.texte" . }}'
        color: '{{ if eq .Status "firing" }}{{ if eq .CommonLabels.severity "critical" }}danger{{ else }}warning{{ end }}{{ else }}good{{ end }}'
EOF
        if [[ "${CANAL_SALON}" != "-" ]]; then echo "        channel: $(yq "${CANAL_SALON}")"; fi ;;
    teams)
        demander CANAL_WEBHOOK_URL "URL du workflow Teams (Power Automate)" ""
        cat <<EOF
    msteamsv2_configs:
      - webhook_url: $(yq "${CANAL_WEBHOOK_URL}")
        send_resolved: true
        title: '{{ template "fr.titre" . }}'
        text: '{{ template "fr.texte" . }}'
EOF
        ;;
    telegram)
        demander TELEGRAM_JETON "Jeton du bot (fourni par @BotFather)" "" secret
        demander TELEGRAM_CHAT_ID "Identifiant de la conversation (chat_id, ex. -1001234567890)" ""
        [[ "${TELEGRAM_CHAT_ID}" =~ ^-?[0-9]+$ ]] || die "chat_id invalide (nombre attendu)"
        cat <<EOF
    telegram_configs:
      - bot_token: $(yq "${TELEGRAM_JETON}")
        chat_id: ${TELEGRAM_CHAT_ID}
        parse_mode: HTML
        send_resolved: true
        message: "{{ template \"fr.titre\" . }}\n\n{{ template \"fr.html\" . }}"
EOF
        ;;
    discord)
        demander CANAL_WEBHOOK_URL "URL du webhook Discord" ""
        cat <<EOF
    discord_configs:
      - webhook_url: $(yq "${CANAL_WEBHOOK_URL}")
        send_resolved: true
        title: '{{ template "fr.titre" . }}'
        message: '{{ template "fr.texte" . }}'
EOF
        ;;
    webex)
        demander WEBEX_JETON "Jeton du bot Webex" "" secret
        demander WEBEX_SALLE "Identifiant de la salle (roomId)" ""
        cat <<EOF
    webex_configs:
      - api_url: "https://webexapis.com/v1/messages"
        room_id: $(yq "${WEBEX_SALLE}")
        send_resolved: true
        message: '{{ template "fr.titre" . }}{{ "\n" }}{{ template "fr.texte" . }}'
        http_config:
          authorization:
            credentials: $(yq "${WEBEX_JETON}")
EOF
        ;;
    pagerduty)
        demander PAGERDUTY_CLE "Clé d'intégration (Events API v2 / routing key)" "" secret
        cat <<EOF
    pagerduty_configs:
      - routing_key: $(yq "${PAGERDUTY_CLE}")
        send_resolved: true
        description: '{{ template "fr.titre" . }}'
        severity: '{{ if eq .CommonLabels.severity "critical" }}critical{{ else }}warning{{ end }}'
EOF
        ;;
    opsgenie)
        demander OPSGENIE_CLE "Clé d'API de l'intégration" "" secret
        demander OPSGENIE_REGION "Région (eu/us)" "eu"
        local u="https://api.opsgenie.com/"; [[ "${OPSGENIE_REGION}" == eu ]] && u="https://api.eu.opsgenie.com/"
        cat <<EOF
    opsgenie_configs:
      - api_key: $(yq "${OPSGENIE_CLE}")
        api_url: "${u}"
        send_resolved: true
        message: '{{ template "fr.titre" . }}'
        description: '{{ template "fr.texte" . }}'
        priority: '{{ if eq .CommonLabels.severity "critical" }}P1{{ else }}P3{{ end }}'
EOF
        ;;
    pushover)
        demander PUSHOVER_UTILISATEUR "Clé utilisateur (ou groupe) Pushover" "" secret
        demander PUSHOVER_JETON "Jeton de l'application Pushover" "" secret
        cat <<EOF
    pushover_configs:
      - user_key: $(yq "${PUSHOVER_UTILISATEUR}")
        token: $(yq "${PUSHOVER_JETON}")
        send_resolved: true
        title: '{{ template "fr.titre" . }}'
        message: '{{ template "fr.texte" . }}'
        priority: '{{ if and (eq .Status "firing") (eq .CommonLabels.severity "critical") }}2{{ else }}0{{ end }}'
        retry: 5m
        expire: 1h
EOF
        ;;
    sms)
        demander SMS_NUMERO "Numéro de téléphone au format international (+33612345678)" ""
        [[ "${SMS_NUMERO}" =~ ^\+[0-9]{8,15}$ ]] || die "Numéro invalide (format +33612345678)"
        demander SNS_REGION "Région AWS" "eu-west-3"
        demander SNS_CLE_ACCES "Clé d'accès AWS (access key)" ""
        demander SNS_CLE_SECRETE "Clé secrète AWS" "" secret
        cat <<EOF
    sns_configs:
      - phone_number: $(yq "${SMS_NUMERO}")
        send_resolved: false
        subject: 'Alerte'
        message: '{{ template "fr.titre" . }} - {{ .CommonAnnotations.summary }}'
        sigv4:
          region: $(yq "${SNS_REGION}")
          access_key: $(yq "${SNS_CLE_ACCES}")
          secret_key: $(yq "${SNS_CLE_SECRETE}")
EOF
        ;;
    jira)
        demander JIRA_URL "URL de Jira (ex. https://societe.atlassian.net)" ""
        demander JIRA_PROJET "Clé du projet (ex. OPS)" ""
        demander JIRA_TYPE "Type de ticket" "Incident"
        demander JIRA_UTILISATEUR "Utilisateur (e-mail du compte de service)" ""
        demander JIRA_JETON "Jeton d'API Jira" "" secret
        cat <<EOF
    jira_configs:
      - api_url: $(yq "${JIRA_URL%/}/rest/api/2")
        project: $(yq "${JIRA_PROJET}")
        issue_type: $(yq "${JIRA_TYPE}")
        send_resolved: true
        summary: '{{ template "fr.titre" . }}'
        description: '{{ template "fr.texte" . }}'
        http_config:
          basic_auth:
            username: $(yq "${JIRA_UTILISATEUR}")
            password: $(yq "${JIRA_JETON}")
EOF
        ;;
    webhook)
        demander CANAL_WEBHOOK_URL "URL appelée (POST JSON au format Alertmanager)" ""
        demander CANAL_JETON "Jeton Bearer (laisser '-' si aucun)" "-" secret
        cat <<EOF
    webhook_configs:
      - url: $(yq "${CANAL_WEBHOOK_URL}")
        send_resolved: true
EOF
        if [[ "${CANAL_JETON}" != "-" ]]; then
            cat <<EOF
        http_config:
          authorization:
            credentials: $(yq "${CANAL_JETON}")
EOF
        fi ;;
    *) die "Type de canal inconnu : ${type}" ;;
    esac
}

canal_ajouter() {
    local type="${1:-}" nom="${2:-}" sev
    require_root
    alertmanager_installe || die "Alertmanager n'est pas installé (étape 01)"
    if [[ -z "${type}" ]]; then
        local i=1 t; for t in "${CANAUX[@]}"; do printf '  %2d) %-11s %s\n' "${i}" "${t}" "$(canal_description "${t}")"; i=$((i + 1)); done
        read -r -p "Type de canal (numéro ou nom) : " type
        [[ "${type}" =~ ^[0-9]+$ ]] && type="${CANAUX[$((type - 1))]:-}"
    fi
    canal_description "${type}" >/dev/null || die "Type de canal inconnu : ${type} (voir : ${SCRIPT_NAME} 04 types)"
    [[ -n "${nom}" ]] || demander CANAL_NOM "Nom du canal (ex. equipe-web)" "${type}"
    nom="${nom:-${CANAL_NOM}}"
    [[ "${nom}" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "Nom invalide : minuscules, chiffres, - et _"
    [[ "${nom}" != aucun ]] || die "Nom réservé : aucun"
    local f="${ALERTMANAGER_CONF_DIR}/canaux.d/${nom}.yml"
    [[ -f "${f}" ]] && { confirm "Le canal ${nom} existe : le remplacer ?" || return 0; }

    if [[ -z "${CANAL_SEVERITES:-}" ]] && interactif; then
        echo "Alertes à envoyer sur ce canal :"
        echo "  1) critiques uniquement"
        echo "  2) critiques et avertissements (conseillé)"
        echo "  3) toutes (y compris informations)"
        local r; read -r -p "Choix [2] : " r
        case "${r:-2}" in 1) CANAL_SEVERITES="critical" ;; 3) CANAL_SEVERITES="critical|warning|info" ;; *) CANAL_SEVERITES="critical|warning" ;; esac
    fi
    sev="${CANAL_SEVERITES:-critical|warning}"
    [[ "${sev}" =~ ^(critical|warning|info)(\|(critical|warning|info))*$ ]] || die "Sévérités invalides : ${sev}"

    titre "Ajout du canal ${nom} (${type})"
    local contenu
    contenu="$(canal_yaml "${type}" "${nom}")" || exit 1
    install -d -m 0750 -o root -g "${ALERTMANAGER_USER}" "${ALERTMANAGER_CONF_DIR}/canaux.d"
    local prec=""; [[ -f "${f}" ]] && prec="$(cat "${f}")"
    printf '# type: %s\n# severites: %s\n%s\n' "${type}" "${sev}" "${contenu}" \
        | ecrire_fichier "${f}" "root:${ALERTMANAGER_USER}" 0640 || exit 1
    if ! appliquer_alertmanager; then
        if [[ -n "${prec}" ]]; then printf '%s\n' "${prec}" > "${f}"; else rm -f "${f}"; fi
        appliquer_alertmanager >/dev/null 2>&1
        die "Canal refusé par Alertmanager (paramètres invalides) : rien n'a été modifié"
    fi
    log_ok "Canal ${nom} actif (sévérités : ${sev})"
    echo "Tester l'envoi : ${SCRIPT_NAME} 04 tester"
}

canal_supprimer() {
    local nom="${1:-}" f
    [[ -n "${nom}" ]] || die "Usage : ${SCRIPT_NAME} 04 supprimer <nom>"
    require_root
    f="${ALERTMANAGER_CONF_DIR}/canaux.d/${nom}.yml"
    [[ -f "${f}" ]] || die "Canal introuvable : ${nom}"
    rm -f "${f}"
    appliquer_alertmanager && log_ok "Canal ${nom} supprimé"
}

canaux_lister() {
    titre "Canaux d'alerte"
    local f n=0
    for f in "${ALERTMANAGER_CONF_DIR}"/canaux.d/*.yml; do
        [[ -f "${f}" ]] || continue
        printf '   %-20s %-11s sévérités : %s\n' "$(basename "${f}" .yml)" \
            "$(awk -F': ' '/^# type:/ {print $2}' "${f}")" "$(awk -F': ' '/^# severites:/ {print $2}' "${f}")"
        n=$((n + 1))
    done
    (( n > 0 )) || echo "   Aucun canal : les alertes ne sont visibles que dans l'interface Alertmanager."
    echo
}

canal_tester() {
    local sev="${1:-critical}"
    cmd_exists "${BIN_DIR}/amtool" || [[ -x "${BIN_DIR}/amtool" ]] || die "amtool introuvable"
    titre "Envoi d'une alerte de test (sévérité ${sev})"
    local fin; fin="$(date -u -d '+5 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    "${BIN_DIR}/amtool" alert add TestPrometheusBundle severity="${sev}" instance="$(nom_hote)" job="test" \
        --annotation=summary="Alerte de test envoyée depuis $(nom_hote)" \
        --annotation=description="Si vous lisez ce message, le canal fonctionne. Aucune action requise." \
        ${fin:+--end="${fin}"} --alertmanager.url="$(am_url)" \
        || die "Envoi impossible à Alertmanager ($(am_url))"
    log_ok "Alerte envoyée : réception attendue sous ${ALERT_GROUP_WAIT} sur les canaux acceptant '${sev}'"
    log_info "En cas d'absence : ${SCRIPT_NAME} 06 journaux alertmanager"
}

etape_04() {
    local action="${1:-}"; shift || true
    case "${action}" in
        types)     titre "Canaux disponibles"; local t
                   for t in "${CANAUX[@]}"; do printf '   %-11s %s\n' "${t}" "$(canal_description "${t}")"; done; echo ;;
        ajouter)   canal_ajouter "$@" ;;
        supprimer) canal_supprimer "$@" ;;
        liste)     canaux_lister ;;
        tester)    canal_tester "$@" ;;
        *) cat <<EOF
04 — Canaux d'alerte
  ${SCRIPT_NAME} 04 types                    canaux disponibles
  ${SCRIPT_NAME} 04 ajouter [type] [nom]     ajoute un canal (questions interactives)
  ${SCRIPT_NAME} 04 liste                    canaux configurés
  ${SCRIPT_NAME} 04 supprimer <nom>          supprime un canal
  ${SCRIPT_NAME} 04 tester [critical|warning] envoie une alerte de test
Plusieurs canaux peuvent coexister (ex. Teams pour tout, SMS pour le critique).
Mode non interactif : variables d'environnement, ex.
  CANAL_WEBHOOK_URL=https://hooks.slack.com/... CANAL_SEVERITES='critical|warning' \\
  ${SCRIPT_NAME} 04 ajouter slack equipe-web
EOF
        ;;
    esac
}

# =============================================================================
#  05 — GRAFANA ET TABLEAUX DE BORD
# =============================================================================
GRAFANA_DASH_DIR="/var/lib/grafana/dashboards/prometheus-bundle"
GRAFANA_PROV_DIR="/etc/grafana/provisioning"
DS_JSON='{"type": "prometheus", "uid": "prometheus-bundle"}'
# Groupe du compte grafana (« grafana » avec les paquets, « root » dans l'image Docker officielle)
grafana_groupe() { id -gn grafana 2>/dev/null || echo grafana; }
LIENS_JSON='[{"title": "Vue d'"'"'ensemble", "type": "link", "url": "/d/prometheus-bundle-vue", "icon": "dashboard", "keepTime": true}, {"title": "Tableaux par application", "type": "dashboards", "tags": ["prometheus-bundle"], "asDropdown": true, "keepTime": true}]'

tableau_de_bord_json() {
    FS_FILTRE_JSON="${FS_FILTRE//\"/\\\"}"
    rendu <<'EOF'
{
  "uid": "prometheus-bundle-vue",
  "title": "Supervision — Vue d'ensemble",
  "description": "Tableau de bord Prometheus-bundle : état des services, alertes, serveurs et sites web",
  "tags": ["prometheus-bundle", "supervision"],
  "links": [{"title": "Tableaux par application", "type": "dashboards", "tags": ["prometheus-bundle"], "asDropdown": true, "keepTime": true}],
  "timezone": "browser",
  "editable": false,
  "graphTooltip": 1,
  "refresh": "1m",
  "schemaVersion": 39,
  "time": {"from": "now-6h", "to": "now"},
  "templating": {
    "list": [
      {
        "name": "serveur",
        "label": "Serveur",
        "type": "query",
        "datasource": {"type": "prometheus", "uid": "prometheus-bundle"},
        "query": {"query": "label_values(node_uname_info, instance)", "refId": "serveur"},
        "definition": "label_values(node_uname_info, instance)",
        "includeAll": true,
        "multi": true,
        "allValue": ".*",
        "current": {"selected": true, "text": ["All"], "value": ["$__all"]},
        "refresh": 2,
        "sort": 1
      }
    ]
  },
  "panels": [
    {"type": "row", "title": "Synthèse", "collapsed": false, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0}, "id": 100, "panels": []},
    {
      "id": 1, "type": "stat", "title": "Services en ligne",
      "description": "Nombre d'agents et d'applications qui répondent à Prometheus (hors sondes web).",
      "gridPos": {"h": 5, "w": 4, "x": 0, "y": 1},
      "datasource": {"type": "prometheus", "uid": "prometheus-bundle"},
      "targets": [{"refId": "A", "expr": "count(up{job!~\"http|tcp|icmp\"} == 1) or vector(0)", "instant": true}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background", "graphMode": "none", "textMode": "value", "justifyMode": "center"},
      "fieldConfig": {"defaults": {"color": {"mode": "fixed", "fixedColor": "green"}, "unit": "none"}, "overrides": []}
    },
    {
      "id": 2, "type": "stat", "title": "Services en panne",
      "description": "Cibles qui ne répondent plus. Doit être à 0.",
      "gridPos": {"h": 5, "w": 4, "x": 4, "y": 1},
      "datasource": {"type": "prometheus", "uid": "prometheus-bundle"},
      "targets": [{"refId": "A", "expr": "count(up{job!~\"http|tcp|icmp\"} == 0) or vector(0)", "instant": true}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background", "graphMode": "none", "textMode": "value", "justifyMode": "center"},
      "fieldConfig": {"defaults": {"color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "red", "value": 1}]}}, "overrides": []}
    },
    {
      "id": 3, "type": "stat", "title": "Alertes critiques",
      "description": "Alertes critiques en cours : intervention immédiate.",
      "gridPos": {"h": 5, "w": 4, "x": 8, "y": 1},
      "datasource": {"type": "prometheus", "uid": "prometheus-bundle"},
      "targets": [{"refId": "A", "expr": "count(ALERTS{alertstate=\"firing\", severity=\"critical\"}) or vector(0)", "instant": true}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background", "graphMode": "none", "textMode": "value", "justifyMode": "center"},
      "fieldConfig": {"defaults": {"color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "red", "value": 1}]}}, "overrides": []}
    },
    {
      "id": 4, "type": "stat", "title": "Avertissements",
      "description": "Alertes de niveau avertissement en cours : à traiter dans la journée.",
      "gridPos": {"h": 5, "w": 4, "x": 12, "y": 1},
      "datasource": {"type": "prometheus", "uid": "prometheus-bundle"},
      "targets": [{"refId": "A", "expr": "count(ALERTS{alertstate=\"firing\", severity=\"warning\"}) or vector(0)", "instant": true}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background", "graphMode": "none", "textMode": "value", "justifyMode": "center"},
      "fieldConfig": {"defaults": {"color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "orange", "value": 1}]}}, "overrides": []}
    },
    {
      "id": 5, "type": "stat", "title": "Sites et ports en échec",
      "description": "Sondes HTTP, TCP et ping en échec.",
      "gridPos": {"h": 5, "w": 4, "x": 16, "y": 1},
      "datasource": {"type": "prometheus", "uid": "prometheus-bundle"},
      "targets": [{"refId": "A", "expr": "count(probe_success == 0) or vector(0)", "instant": true}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background", "graphMode": "none", "textMode": "value", "justifyMode": "center"},
      "fieldConfig": {"defaults": {"color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "red", "value": 1}]}}, "overrides": []}
    },
    {
      "id": 6, "type": "stat", "title": "Disponibilité (24 h)",
      "description": "Part du temps où l'ensemble des cibles a répondu sur les dernières 24 heures.",
      "gridPos": {"h": 5, "w": 4, "x": 20, "y": 1},
      "datasource": {"type": "prometheus", "uid": "prometheus-bundle"},
      "targets": [{"refId": "A", "expr": "avg(avg_over_time(up{job!~\"http|tcp|icmp\"}[24h]))", "instant": true}],
      "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background", "graphMode": "none", "textMode": "value", "justifyMode": "center"},
      "fieldConfig": {"defaults": {"unit": "percentunit", "decimals": 2, "min": 0, "max": 1, "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "red", "value": null}, {"color": "orange", "value": 0.95}, {"color": "green", "value": 0.99}]}}, "overrides": []}
    },
    {"type": "row", "title": "Alertes en cours", "collapsed": false, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 6}, "id": 101, "panels": []},
    {
      "id": 7, "type": "table", "title": "Alertes actives",
      "description": "Liste des alertes en cours. Une ligne rouge = critique, orange = avertissement.",
      "gridPos": {"h": 8, "w": 24, "x": 0, "y": 7},
      "datasource": {"type": "prometheus", "uid": "prometheus-bundle"},
      "targets": [{"refId": "A", "expr": "count by (severity, alertname, instance, job) (ALERTS{alertstate=\"firing\", alertname!=\"Watchdog\"})", "instant": true, "format": "table"}],
      "options": {"showHeader": true, "cellHeight": "sm", "footer": {"show": false}, "sortBy": [{"displayName": "Gravité", "desc": false}]},
      "transformations": [
        {"id": "organize", "options": {
          "excludeByName": {"Time": true, "Value": true},
          "indexByName": {"severity": 0, "alertname": 1, "instance": 2, "job": 3},
          "renameByName": {"severity": "Gravité", "alertname": "Alerte", "instance": "Instance", "job": "Application"}
        }}
      ],
      "fieldConfig": {
        "defaults": {"noValue": "Aucune alerte en cours", "custom": {"align": "left", "filterable": true}},
        "overrides": [
          {"matcher": {"id": "byName", "options": "Gravité"}, "properties": [
            {"id": "custom.width", "value": 150},
            {"id": "custom.cellOptions", "value": {"type": "color-background"}},
            {"id": "mappings", "value": [{"type": "value", "options": {
              "critical": {"text": "CRITIQUE", "color": "red", "index": 0},
              "warning": {"text": "AVERTISSEMENT", "color": "orange", "index": 1},
              "info": {"text": "INFO", "color": "blue", "index": 2}}}]}
          ]}
        ]
      }
    },
    {"type": "row", "title": "État des services", "collapsed": false, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 15}, "id": 102, "panels": []},
    {
      "id": 8, "type": "table", "title": "Agents et cibles",
      "description": "Chaque cible collectée par Prometheus : EN LIGNE ou EN PANNE.",
      "gridPos": {"h": 10, "w": 12, "x": 0, "y": 16},
      "datasource": {"type": "prometheus", "uid": "prometheus-bundle"},
      "targets": [{"refId": "A", "expr": "up{job!~\"http|tcp|icmp\"}", "instant": true, "format": "table"}],
      "options": {"showHeader": true, "cellHeight": "sm", "footer": {"show": false}, "sortBy": [{"displayName": "État", "desc": false}]},
      "transformations": [
        {"id": "organize", "options": {
          "excludeByName": {"Time": true, "__name__": true},
          "indexByName": {"Value": 0, "job": 1, "instance": 2},
          "renameByName": {"Value": "État", "job": "Application", "instance": "Cible"}
        }}
      ],
      "fieldConfig": {
        "defaults": {"custom": {"align": "left", "filterable": true}},
        "overrides": [
          {"matcher": {"id": "byName", "options": "État"}, "properties": [
            {"id": "custom.width", "value": 120},
            {"id": "custom.cellOptions", "value": {"type": "color-background"}},
            {"id": "mappings", "value": [{"type": "value", "options": {
              "1": {"text": "EN LIGNE", "color": "green", "index": 0},
              "0": {"text": "EN PANNE", "color": "red", "index": 1}}}]}
          ]}
        ]
      }
    },
    {
      "id": 9, "type": "table", "title": "Applications",
      "description": "L'application elle-même répond-elle à son agent ? (base de données, serveur web, cache...)",
      "gridPos": {"h": 10, "w": 12, "x": 12, "y": 16},
      "datasource": {"type": "prometheus", "uid": "prometheus-bundle"},
      "targets": [{"refId": "A", "instant": true, "format": "table",
        "expr": "label_replace(mysql_up, \"application\", \"MySQL / MariaDB\", \"\", \"\") or label_replace(pg_up, \"application\", \"PostgreSQL\", \"\", \"\") or label_replace(redis_up, \"application\", \"Redis\", \"\", \"\") or label_replace(mongodb_up, \"application\", \"MongoDB\", \"\", \"\") or label_replace(memcached_up, \"application\", \"Memcached\", \"\", \"\") or label_replace(elasticsearch_cluster_health_up, \"application\", \"Elasticsearch\", \"\", \"\") or label_replace(nginx_up, \"application\", \"Nginx\", \"\", \"\") or label_replace(apache_up, \"application\", \"Apache\", \"\", \"\") or label_replace(phpfpm_up, \"application\", \"PHP-FPM\", \"\", \"\") or label_replace(up{job=~\"haproxy|rabbitmq|kafka|jvm|springboot|application|windows|docker\"}, \"application\", \"$1\", \"job\", \"(.*)\") or label_replace(clamp_max(namedprocess_namegroup_num_procs, 1), \"application\", \"Processus $1\", \"groupname\", \"(.*)\")"}],
      "options": {"showHeader": true, "cellHeight": "sm", "footer": {"show": false}, "sortBy": [{"displayName": "État", "desc": false}]},
      "transformations": [
        {"id": "organize", "options": {
          "excludeByName": {"Time": true, "__name__": true, "job": true, "groupname": true, "pool": true, "scrape_uri": true, "cluster": true, "addr": true},
          "indexByName": {"Value": 0, "application": 1, "instance": 2},
          "renameByName": {"Value": "État", "application": "Application", "instance": "Instance"}
        }}
      ],
      "fieldConfig": {
        "defaults": {"noValue": "Aucune application déclarée (étape 03)", "custom": {"align": "left", "filterable": true}},
        "overrides": [
          {"matcher": {"id": "byName", "options": "État"}, "properties": [
            {"id": "custom.width", "value": 120},
            {"id": "custom.cellOptions", "value": {"type": "color-background"}},
            {"id": "mappings", "value": [{"type": "value", "options": {
              "1": {"text": "OK", "color": "green", "index": 0},
              "0": {"text": "ARRÊTÉ", "color": "red", "index": 1}}}]}
          ]}
        ]
      }
    },
    {"type": "row", "title": "Serveurs", "collapsed": false, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 26}, "id": 103, "panels": []},
    {
      "id": 10, "type": "bargauge", "title": "Processeur (%)",
      "description": "Orange au-delà de @@SEUIL_CPU_WARN@@ %, rouge au-delà de @@SEUIL_CPU_CRIT@@ %.",
      "gridPos": {"h": 7, "w": 8, "x": 0, "y": 27},
      "datasource": {"type": "prometheus", "uid": "prometheus-bundle"},
      "targets": [{"refId": "A", "instant": true, "legendFormat": "{{instance}}", "expr": "100 - avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\", instance=~\"$serveur\"}[5m])) * 100"}],
      "options": {"orientation": "horizontal", "displayMode": "basic", "showUnfilled": true, "valueMode": "color", "namePlacement": "left", "reduceOptions": {"calcs": ["lastNotNull"]}},
      "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100, "decimals": 0, "noValue": "Aucun serveur Linux (03 agent linux)", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "orange", "value": @@SEUIL_CPU_WARN@@}, {"color": "red", "value": @@SEUIL_CPU_CRIT@@}]}}, "overrides": []}
    },
    {
      "id": 11, "type": "bargauge", "title": "Mémoire (%)",
      "description": "Orange au-delà de @@SEUIL_MEMOIRE_WARN@@ %, rouge au-delà de @@SEUIL_MEMOIRE_CRIT@@ %.",
      "gridPos": {"h": 7, "w": 8, "x": 8, "y": 27},
      "datasource": {"type": "prometheus", "uid": "prometheus-bundle"},
      "targets": [{"refId": "A", "instant": true, "legendFormat": "{{instance}}", "expr": "(1 - node_memory_MemAvailable_bytes{instance=~\"$serveur\"} / node_memory_MemTotal_bytes{instance=~\"$serveur\"}) * 100"}],
      "options": {"orientation": "horizontal", "displayMode": "basic", "showUnfilled": true, "valueMode": "color", "namePlacement": "left", "reduceOptions": {"calcs": ["lastNotNull"]}},
      "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100, "decimals": 0, "noValue": "Aucun serveur Linux", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "orange", "value": @@SEUIL_MEMOIRE_WARN@@}, {"color": "red", "value": @@SEUIL_MEMOIRE_CRIT@@}]}}, "overrides": []}
    },
    {
      "id": 12, "type": "bargauge", "title": "Disque le plus rempli (%)",
      "description": "Remplissage du système de fichiers le plus plein de chaque serveur. Orange au-delà de @@SEUIL_DISQUE_WARN@@ %, rouge au-delà de @@SEUIL_DISQUE_CRIT@@ %.",
      "gridPos": {"h": 7, "w": 8, "x": 16, "y": 27},
      "datasource": {"type": "prometheus", "uid": "prometheus-bundle"},
      "targets": [{"refId": "A", "instant": true, "legendFormat": "{{instance}}", "expr": "max by (instance) ((1 - node_filesystem_avail_bytes{instance=~\"$serveur\", @@FS_FILTRE_JSON@@} / node_filesystem_size_bytes{instance=~\"$serveur\", @@FS_FILTRE_JSON@@}) * 100)"}],
      "options": {"orientation": "horizontal", "displayMode": "basic", "showUnfilled": true, "valueMode": "color", "namePlacement": "left", "reduceOptions": {"calcs": ["lastNotNull"]}},
      "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100, "decimals": 0, "noValue": "Aucun serveur Linux", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "orange", "value": @@SEUIL_DISQUE_WARN@@}, {"color": "red", "value": @@SEUIL_DISQUE_CRIT@@}]}}, "overrides": []}
    },
    {
      "id": 13, "type": "timeseries", "title": "Processeur dans le temps (%)",
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 35},
      "datasource": {"type": "prometheus", "uid": "prometheus-bundle"},
      "targets": [{"refId": "A", "legendFormat": "{{instance}}", "expr": "100 - avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\", instance=~\"$serveur\"}[$__rate_interval])) * 100"}],
      "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100, "custom": {"lineWidth": 2, "fillOpacity": 10, "showPoints": "never", "thresholdsStyle": {"mode": "dashed"}}, "color": {"mode": "palette-classic"}, "thresholds": {"mode": "absolute", "steps": [{"color": "transparent", "value": null}, {"color": "red", "value": @@SEUIL_CPU_CRIT@@}]}}, "overrides": []}
    },
    {
      "id": 14, "type": "timeseries", "title": "Mémoire dans le temps (%)",
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 35},
      "datasource": {"type": "prometheus", "uid": "prometheus-bundle"},
      "targets": [{"refId": "A", "legendFormat": "{{instance}}", "expr": "(1 - node_memory_MemAvailable_bytes{instance=~\"$serveur\"} / node_memory_MemTotal_bytes{instance=~\"$serveur\"}) * 100"}],
      "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100, "custom": {"lineWidth": 2, "fillOpacity": 10, "showPoints": "never", "thresholdsStyle": {"mode": "dashed"}}, "color": {"mode": "palette-classic"}, "thresholds": {"mode": "absolute", "steps": [{"color": "transparent", "value": null}, {"color": "red", "value": @@SEUIL_MEMOIRE_CRIT@@}]}}, "overrides": []}
    },
    {"type": "row", "title": "Sites web et sondes", "collapsed": false, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 43}, "id": 104, "panels": []},
    {
      "id": 15, "type": "table", "title": "Sites, ports et équipements surveillés",
      "description": "Résultat des sondes HTTP, TCP et ping, temps de réponse et jours restants avant expiration du certificat.",
      "gridPos": {"h": 9, "w": 12, "x": 0, "y": 44},
      "datasource": {"type": "prometheus", "uid": "prometheus-bundle"},
      "targets": [
        {"refId": "A", "expr": "max by (job, instance) (probe_success)", "instant": true, "format": "table"},
        {"refId": "B", "expr": "max by (job, instance) (probe_duration_seconds)", "instant": true, "format": "table"},
        {"refId": "C", "expr": "max by (job, instance) ((probe_ssl_earliest_cert_expiry - time()) / 86400)", "instant": true, "format": "table"}
      ],
      "options": {"showHeader": true, "cellHeight": "sm", "footer": {"show": false}, "sortBy": [{"displayName": "État", "desc": false}]},
      "transformations": [
        {"id": "merge", "options": {}},
        {"id": "organize", "options": {
          "excludeByName": {"Time": true, "__name__": true},
          "indexByName": {"Value #A": 0, "job": 1, "instance": 2, "Value #B": 3, "Value #C": 4},
          "renameByName": {"Value #A": "État", "job": "Type", "instance": "Adresse", "Value #B": "Temps de réponse", "Value #C": "Certificat (jours)"}
        }}
      ],
      "fieldConfig": {
        "defaults": {"noValue": "—", "custom": {"align": "left"}},
        "overrides": [
          {"matcher": {"id": "byName", "options": "État"}, "properties": [
            {"id": "custom.width", "value": 100},
            {"id": "custom.cellOptions", "value": {"type": "color-background"}},
            {"id": "mappings", "value": [{"type": "value", "options": {
              "1": {"text": "OK", "color": "green", "index": 0},
              "0": {"text": "ÉCHEC", "color": "red", "index": 1}}}]}
          ]},
          {"matcher": {"id": "byName", "options": "Temps de réponse"}, "properties": [
            {"id": "unit", "value": "s"}, {"id": "decimals", "value": 2},
            {"id": "custom.cellOptions", "value": {"type": "color-text"}},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "orange", "value": @@SEUIL_HTTP_LATENCE_S@@}]}}
          ]},
          {"matcher": {"id": "byName", "options": "Certificat (jours)"}, "properties": [
            {"id": "decimals", "value": 0},
            {"id": "custom.cellOptions", "value": {"type": "color-text"}},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [{"color": "red", "value": null}, {"color": "orange", "value": @@SEUIL_CERT_JOURS_CRIT@@}, {"color": "green", "value": @@SEUIL_CERT_JOURS_WARN@@}]}}
          ]}
        ]
      }
    },
    {
      "id": 16, "type": "timeseries", "title": "Temps de réponse des sites",
      "gridPos": {"h": 9, "w": 12, "x": 12, "y": 44},
      "datasource": {"type": "prometheus", "uid": "prometheus-bundle"},
      "targets": [{"refId": "A", "legendFormat": "{{instance}}", "expr": "probe_duration_seconds{job=\"http\"}"}],
      "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "fieldConfig": {"defaults": {"unit": "s", "min": 0, "noValue": "Aucun site surveillé", "custom": {"lineWidth": 2, "fillOpacity": 10, "showPoints": "never", "thresholdsStyle": {"mode": "dashed"}}, "color": {"mode": "palette-classic"}, "thresholds": {"mode": "absolute", "steps": [{"color": "transparent", "value": null}, {"color": "orange", "value": @@SEUIL_HTTP_LATENCE_S@@}]}}, "overrides": []}
    }
  ]
}
EOF
}


# --- Tableaux par application -------------------------------------------------
TABLEAUX=(linux windows sondes mysql postgresql redis mongodb memcached elasticsearch
          nginx apache phpfpm haproxy rabbitmq kafka jvm process docker application)

# Application (clé du catalogue) -> tableau de bord
tableau_de_app() {
    case "$1" in http|tcp|icmp) echo sondes ;; springboot) echo jvm ;; *) echo "$1" ;; esac
}

# tableau_meta <tableau> : TB_TITRE, TB_JOBS (regex des jobs), TB_VAR (requête de la liste des instances)
tableau_meta() {
    TB_JOBS="$1"; TB_VAR=""
    case "$1" in
        linux)         TB_TITRE="Serveur Linux" ;;
        windows)       TB_TITRE="Serveur Windows" ;;
        sondes)        TB_TITRE="Sites web et sondes"; TB_JOBS="http|tcp|icmp"; TB_VAR="label_values(probe_success, instance)" ;;
        mysql)         TB_TITRE="MySQL / MariaDB" ;;
        postgresql)    TB_TITRE="PostgreSQL" ;;
        redis)         TB_TITRE="Redis" ;;
        mongodb)       TB_TITRE="MongoDB" ;;
        memcached)     TB_TITRE="Memcached" ;;
        elasticsearch) TB_TITRE="Elasticsearch" ;;
        nginx)         TB_TITRE="Nginx" ;;
        apache)        TB_TITRE="Apache httpd" ;;
        phpfpm)        TB_TITRE="PHP-FPM" ;;
        haproxy)       TB_TITRE="HAProxy" ;;
        rabbitmq)      TB_TITRE="RabbitMQ" ;;
        kafka)         TB_TITRE="Kafka" ;;
        jvm)           TB_TITRE="Applications Java / Spring Boot"; TB_JOBS="jvm|springboot" ;;
        process)       TB_TITRE="Processus" ;;
        docker)        TB_TITRE="Conteneurs Docker" ;;
        application)   TB_TITRE="Application instrumentée"; TB_JOBS="application.*" ;;
        *) return 1 ;;
    esac
    [[ -n "${TB_VAR}" ]] || TB_VAR="label_values(up{job=~\"${TB_JOBS}\"}, instance)"
}

# Description compacte des panneaux, une ligne par panneau :
#   type§largeur§titre§unité§seuils§requête##légende;;requête##légende
# type : etat (1=OK/0=EN PANNE), couleur (0 vert/1 jaune/2 rouge), stat, gauge, bargauge, ts (courbe)
# seuils : "orange,rouge" ou "inv:rouge_sous,vert_au_dessus" ; @SEL@ = filtre job + instance choisie
tableau_spec() {
    case "$1" in
linux) cat <<'EOF' ;;
etat§4§Disponibilité§§§up{@SEL@}
stat§4§Démarré depuis§s§§time() - node_boot_time_seconds{@SEL@}
stat§4§Processeurs§short§§count(node_cpu_seconds_total{@SEL@, mode="idle"})
stat§4§Mémoire totale§bytes§§node_memory_MemTotal_bytes{@SEL@}
stat§4§Services systemd en échec§short§1,1§count(node_systemd_unit_state{@SEL@, state="failed"} == 1) or vector(0)
stat§4§Charge (15 min)§short§§node_load15{@SEL@}
gauge§8§Processeur§percent§@@SEUIL_CPU_WARN@@,@@SEUIL_CPU_CRIT@@§100 - avg(rate(node_cpu_seconds_total{@SEL@, mode="idle"}[5m])) * 100
gauge§8§Mémoire§percent§@@SEUIL_MEMOIRE_WARN@@,@@SEUIL_MEMOIRE_CRIT@@§(1 - node_memory_MemAvailable_bytes{@SEL@} / node_memory_MemTotal_bytes{@SEL@}) * 100
gauge§8§Swap§percent§50,80§(1 - node_memory_SwapFree_bytes{@SEL@} / node_memory_SwapTotal_bytes{@SEL@}) * 100
ts§12§Processeur par activité§percent§§sum by (mode) (rate(node_cpu_seconds_total{@SEL@, mode!="idle"}[$__rate_interval])) / scalar(count(node_cpu_seconds_total{@SEL@, mode="idle"})) * 100##{{mode}}
ts§12§Charge moyenne§short§§node_load1{@SEL@}##1 min;;node_load5{@SEL@}##5 min;;node_load15{@SEL@}##15 min
ts§12§Mémoire§bytes§§node_memory_MemTotal_bytes{@SEL@} - node_memory_MemAvailable_bytes{@SEL@}##utilisée;;node_memory_Cached_bytes{@SEL@} + node_memory_Buffers_bytes{@SEL@}##cache;;node_memory_MemAvailable_bytes{@SEL@}##disponible
bargauge§12§Remplissage des disques§percent§@@SEUIL_DISQUE_WARN@@,@@SEUIL_DISQUE_CRIT@@§(1 - node_filesystem_avail_bytes{@SEL@, @@FS_FILTRE@@} / node_filesystem_size_bytes{@SEL@, @@FS_FILTRE@@}) * 100##{{mountpoint}}
ts§12§Débit disque§Bps§§sum by (device) (rate(node_disk_read_bytes_total{@SEL@}[$__rate_interval]))##lecture {{device}};;sum by (device) (rate(node_disk_written_bytes_total{@SEL@}[$__rate_interval]))##écriture {{device}}
ts§12§Trafic réseau§bps§§sum by (device) (rate(node_network_receive_bytes_total{@SEL@, device!~"lo|veth.*|docker.*|br-.*"}[$__rate_interval])) * 8##reçu {{device}};;sum by (device) (rate(node_network_transmit_bytes_total{@SEL@, device!~"lo|veth.*|docker.*|br-.*"}[$__rate_interval])) * 8##émis {{device}}
EOF
windows) cat <<'EOF' ;;
etat§4§Disponibilité§§§up{@SEL@}
stat§4§Démarré depuis§s§§time() - windows_system_boot_time_timestamp_seconds{@SEL@}
stat§4§Processeurs§short§§count(windows_cpu_time_total{@SEL@, mode="idle"})
stat§4§Mémoire totale§bytes§§windows_memory_physical_total_bytes{@SEL@}
stat§8§Services automatiques arrêtés§short§1,1§count(windows_service_state{@SEL@, state="stopped"} == 1 and on (instance, name) windows_service_start_mode{start_mode="auto"} == 1) or vector(0)
gauge§8§Processeur§percent§@@SEUIL_CPU_WARN@@,@@SEUIL_CPU_CRIT@@§100 - avg(rate(windows_cpu_time_total{@SEL@, mode="idle"}[5m])) * 100
gauge§8§Mémoire§percent§@@SEUIL_MEMOIRE_WARN@@,@@SEUIL_MEMOIRE_CRIT@@§100 - windows_memory_available_bytes{@SEL@} / windows_memory_physical_total_bytes{@SEL@} * 100
bargauge§8§Disques§percent§@@SEUIL_DISQUE_WARN@@,@@SEUIL_DISQUE_CRIT@@§100 - windows_logical_disk_free_bytes{@SEL@, volume!~"HarddiskVolume.*"} / windows_logical_disk_size_bytes{@SEL@, volume!~"HarddiskVolume.*"} * 100##{{volume}}
ts§12§Processeur§percent§§100 - avg(rate(windows_cpu_time_total{@SEL@, mode="idle"}[$__rate_interval])) * 100##processeur
ts§12§Trafic réseau§bps§§sum by (nic) (rate(windows_net_bytes_received_total{@SEL@}[$__rate_interval])) * 8##reçu {{nic}};;sum by (nic) (rate(windows_net_bytes_sent_total{@SEL@}[$__rate_interval])) * 8##émis {{nic}}
EOF
sondes) cat <<'EOF' ;;
etat§4§État§§§probe_success{@SEL@}
stat§4§Code HTTP§none§§probe_http_status_code{@SEL@}
stat§4§Temps de réponse§s§@@SEUIL_HTTP_LATENCE_S@@,@@SEUIL_HTTP_LATENCE_S@@§probe_duration_seconds{@SEL@}
stat§4§Certificat (jours restants)§short§inv:@@SEUIL_CERT_JOURS_CRIT@@,@@SEUIL_CERT_JOURS_WARN@@§(probe_ssl_earliest_cert_expiry{@SEL@} - time()) / 86400
stat§4§Disponibilité 24 h§percentunit§inv:0.95,0.99§avg_over_time(probe_success{@SEL@}[24h])
stat§4§Disponibilité 30 jours§percentunit§inv:0.95,0.99§avg_over_time(probe_success{@SEL@}[30d])
ts§24§Temps de réponse par phase (HTTP)§s§§probe_http_duration_seconds{@SEL@}##{{phase}}
ts§12§Résultat de la sonde (1 = OK)§short§§probe_success{@SEL@}##{{instance}}
ts§12§Temps de réponse total§s§@@SEUIL_HTTP_LATENCE_S@@,@@SEUIL_HTTP_LATENCE_S@@§probe_duration_seconds{@SEL@}##{{instance}}
EOF
mysql) cat <<'EOF' ;;
etat§4§MySQL§§§mysql_up{@SEL@}
stat§4§Démarré depuis§s§§mysql_global_status_uptime{@SEL@}
stat§4§Connexions§short§§mysql_global_status_threads_connected{@SEL@}
gauge§4§Connexions utilisées§percent§@@SEUIL_CONNEXIONS_PCT@@,95§mysql_global_status_threads_connected{@SEL@} / mysql_global_variables_max_connections{@SEL@} * 100
stat§4§Requêtes en cours§short§20,50§mysql_global_status_threads_running{@SEL@}
stat§4§Retard de réplication§s§@@SEUIL_REPLICATION_RETARD_S@@,@@SEUIL_REPLICATION_RETARD_S@@§mysql_slave_status_seconds_behind_master{@SEL@}
ts§12§Requêtes par seconde§ops§§rate(mysql_global_status_queries{@SEL@}[$__rate_interval])##requêtes;;rate(mysql_global_status_slow_queries{@SEL@}[$__rate_interval])##lentes
ts§12§Commandes SQL§ops§§rate(mysql_global_status_commands_total{@SEL@, command=~"select|insert|update|delete|replace|commit|rollback"}[$__rate_interval])##{{command}}
ts§12§Connexions§short§§mysql_global_status_threads_connected{@SEL@}##connectées;;mysql_global_status_threads_running{@SEL@}##actives;;mysql_global_variables_max_connections{@SEL@}##maximum
ts§12§Pool de tampons InnoDB§bytes§§mysql_global_status_innodb_buffer_pool_bytes_data{@SEL@}##données;;mysql_global_variables_innodb_buffer_pool_size{@SEL@}##taille
ts§12§Trafic réseau§Bps§§rate(mysql_global_status_bytes_received{@SEL@}[$__rate_interval])##reçu;;rate(mysql_global_status_bytes_sent{@SEL@}[$__rate_interval])##envoyé
ts§12§Attentes de verrous§ops§§rate(mysql_global_status_innodb_row_lock_waits{@SEL@}[$__rate_interval])##lignes InnoDB;;rate(mysql_global_status_table_locks_waited{@SEL@}[$__rate_interval])##tables
EOF
postgresql) cat <<'EOF' ;;
etat§4§PostgreSQL§§§pg_up{@SEL@}
stat§4§Démarré depuis§s§§time() - pg_postmaster_start_time_seconds{@SEL@}
stat§4§Connexions§short§§sum(pg_stat_activity_count{@SEL@})
gauge§4§Connexions utilisées§percent§@@SEUIL_CONNEXIONS_PCT@@,95§sum(pg_stat_activity_count{@SEL@}) / max(pg_settings_max_connections{@SEL@}) * 100
stat§4§Taille des bases§bytes§§sum(pg_database_size_bytes{@SEL@})
stat§4§Retard de réplication§s§@@SEUIL_REPLICATION_RETARD_S@@,@@SEUIL_REPLICATION_RETARD_S@@§max(pg_replication_lag_seconds{@SEL@}) and max(pg_replication_is_replica{@SEL@}) == 1
ts§12§Transactions par seconde§ops§§sum(rate(pg_stat_database_xact_commit{@SEL@}[$__rate_interval]))##validées;;sum(rate(pg_stat_database_xact_rollback{@SEL@}[$__rate_interval]))##annulées
ts§12§Connexions par état§short§§sum by (state) (pg_stat_activity_count{@SEL@})##{{state}}
ts§12§Lignes lues et écrites§ops§§sum(rate(pg_stat_database_tup_fetched{@SEL@}[$__rate_interval]))##lues;;sum(rate(pg_stat_database_tup_inserted{@SEL@}[$__rate_interval]))##insérées;;sum(rate(pg_stat_database_tup_updated{@SEL@}[$__rate_interval]))##modifiées;;sum(rate(pg_stat_database_tup_deleted{@SEL@}[$__rate_interval]))##supprimées
ts§12§Taux de lecture en cache§percentunit§§sum(rate(pg_stat_database_blks_hit{@SEL@}[$__rate_interval])) / (sum(rate(pg_stat_database_blks_hit{@SEL@}[$__rate_interval])) + sum(rate(pg_stat_database_blks_read{@SEL@}[$__rate_interval])))##cache
bargauge§12§Taille par base§bytes§§pg_database_size_bytes{@SEL@, datname!~"template.*"}##{{datname}}
ts§12§Verrous et interblocages§short§§sum by (mode) (pg_locks_count{@SEL@})##{{mode}};;sum(increase(pg_stat_database_deadlocks{@SEL@}[$__rate_interval]))##interblocages
EOF
redis) cat <<'EOF' ;;
etat§4§Redis§§§redis_up{@SEL@}
stat§4§Démarré depuis§s§§redis_uptime_in_seconds{@SEL@}
stat§4§Clients connectés§short§§redis_connected_clients{@SEL@}
stat§4§Mémoire utilisée§bytes§§redis_memory_used_bytes{@SEL@}
stat§4§Clés§short§§sum(redis_db_keys{@SEL@})
stat§4§Taux de succès du cache§percentunit§inv:0.8,0.9§rate(redis_keyspace_hits_total{@SEL@}[5m]) / (rate(redis_keyspace_hits_total{@SEL@}[5m]) + rate(redis_keyspace_misses_total{@SEL@}[5m]))
ts§12§Commandes par seconde§ops§§rate(redis_commands_processed_total{@SEL@}[$__rate_interval])##commandes
ts§12§Mémoire§bytes§§redis_memory_used_bytes{@SEL@}##utilisée;;redis_memory_max_bytes{@SEL@} > 0##maximum
ts§12§Lectures trouvées / manquées§ops§§rate(redis_keyspace_hits_total{@SEL@}[$__rate_interval])##trouvées;;rate(redis_keyspace_misses_total{@SEL@}[$__rate_interval])##manquées
ts§12§Clés évincées et expirées§ops§§rate(redis_evicted_keys_total{@SEL@}[$__rate_interval])##évincées;;rate(redis_expired_keys_total{@SEL@}[$__rate_interval])##expirées
EOF
mongodb) cat <<'EOF' ;;
etat§6§MongoDB§§§mongodb_up{@SEL@}
stat§6§Démarré depuis§s§§mongodb_ss_uptime{@SEL@}
stat§6§Connexions§short§§mongodb_ss_connections{@SEL@, conn_type="current"}
stat§6§Membres du replica set en panne§short§1,1§count(mongodb_rs_members_health{@SEL@} == 0) or vector(0)
ts§12§Opérations par seconde§ops§§sum by (legacy_op_type) (rate(mongodb_ss_opcounters{@SEL@}[$__rate_interval]))##{{legacy_op_type}}
ts§12§Connexions§short§§mongodb_ss_connections{@SEL@, conn_type="current"}##actives;;mongodb_ss_connections{@SEL@, conn_type="available"}##disponibles
ts§12§Mémoire résidente§bytes§§mongodb_ss_mem_resident{@SEL@} * 1024 * 1024##résidente
ts§12§Retard de réplication§s§@@SEUIL_REPLICATION_RETARD_S@@,@@SEUIL_REPLICATION_RETARD_S@@§mongodb_mongod_replset_member_replication_lag{@SEL@}##{{name}}
EOF
memcached) cat <<'EOF' ;;
etat§6§Memcached§§§memcached_up{@SEL@}
stat§6§Connexions§short§§memcached_current_connections{@SEL@}
stat§6§Éléments en cache§short§§memcached_current_items{@SEL@}
gauge§6§Mémoire utilisée§percent§80,95§memcached_current_bytes{@SEL@} / memcached_limit_bytes{@SEL@} * 100
ts§12§Commandes par seconde§ops§§sum by (command, status) (rate(memcached_commands_total{@SEL@}[$__rate_interval]))##{{command}} {{status}}
ts§12§Évictions§ops§§rate(memcached_items_evicted_total{@SEL@}[$__rate_interval])##évictions
EOF
elasticsearch) cat <<'EOF' ;;
etat§4§Agent§§§elasticsearch_cluster_health_up{@SEL@}
couleur§4§État du cluster§§§max(elasticsearch_cluster_health_status{@SEL@, color="yellow"}) + 2 * max(elasticsearch_cluster_health_status{@SEL@, color="red"})
stat§4§Nœuds§short§§max(elasticsearch_cluster_health_number_of_nodes{@SEL@})
stat§4§Shards non alloués§short§1,1§max(elasticsearch_cluster_health_unassigned_shards{@SEL@})
stat§4§Documents§short§§sum(elasticsearch_indices_docs{@SEL@})
stat§4§Volume des données§bytes§§sum(elasticsearch_indices_store_size_bytes{@SEL@})
bargauge§12§Heap JVM par nœud§percent§@@SEUIL_JVM_HEAP_PCT@@,95§elasticsearch_jvm_memory_used_bytes{@SEL@, area="heap"} / elasticsearch_jvm_memory_max_bytes{@SEL@, area="heap"} * 100##{{name}}
bargauge§12§Disque par nœud§percent§85,95§(1 - elasticsearch_filesystem_data_available_bytes{@SEL@} / elasticsearch_filesystem_data_size_bytes{@SEL@}) * 100##{{name}}
ts§12§Indexations et recherches§ops§§sum(rate(elasticsearch_indices_indexing_index_total{@SEL@}[$__rate_interval]))##indexations;;sum(rate(elasticsearch_indices_search_query_total{@SEL@}[$__rate_interval]))##recherches
ts§12§Temps passé en GC§s§§sum by (name) (rate(elasticsearch_jvm_gc_collection_seconds_sum{@SEL@}[$__rate_interval]))##{{name}}
EOF
nginx) cat <<'EOF' ;;
etat§6§Nginx§§§nginx_up{@SEL@}
stat§6§Connexions actives§short§@@SEUIL_NGINX_CONNEXIONS@@,@@SEUIL_NGINX_CONNEXIONS@@§nginx_connections_active{@SEL@}
stat§6§Requêtes par seconde§reqps§§rate(nginx_http_requests_total{@SEL@}[5m])
stat§6§Connexions abandonnées (5 min)§short§1,1§increase(nginx_connections_accepted{@SEL@}[5m]) - increase(nginx_connections_handled{@SEL@}[5m])
ts§12§Requêtes par seconde§reqps§§rate(nginx_http_requests_total{@SEL@}[$__rate_interval])##requêtes
ts§12§Connexions§short§§nginx_connections_active{@SEL@}##actives;;nginx_connections_reading{@SEL@}##lecture;;nginx_connections_writing{@SEL@}##écriture;;nginx_connections_waiting{@SEL@}##en attente
EOF
apache) cat <<'EOF' ;;
etat§6§Apache§§§apache_up{@SEL@}
stat§6§Démarré depuis§s§§apache_uptime_seconds_total{@SEL@}
gauge§6§Workers occupés§percent§80,95§sum(apache_workers{@SEL@, state="busy"}) / sum(apache_workers{@SEL@}) * 100
stat§6§Requêtes par seconde§reqps§§rate(apache_accesses_total{@SEL@}[5m])
ts§12§Requêtes par seconde§reqps§§rate(apache_accesses_total{@SEL@}[$__rate_interval])##requêtes
ts§12§Workers§short§§apache_workers{@SEL@}##{{state}}
EOF
phpfpm) cat <<'EOF' ;;
etat§6§PHP-FPM§§§min(phpfpm_up{@SEL@})
stat§6§Processus actifs§short§§sum(phpfpm_active_processes{@SEL@})
stat§6§File d'attente§short§@@SEUIL_PHPFPM_FILE_ATTENTE@@,@@SEUIL_PHPFPM_FILE_ATTENTE@@§sum(phpfpm_listen_queue{@SEL@})
stat§6§Saturations du pool (1 h)§short§1,1§sum(increase(phpfpm_max_children_reached{@SEL@}[1h]))
ts§12§Processus par pool§short§§phpfpm_active_processes{@SEL@}##actifs {{pool}};;phpfpm_idle_processes{@SEL@}##libres {{pool}}
ts§12§Requêtes par seconde§reqps§§sum by (pool) (rate(phpfpm_accepted_connections{@SEL@}[$__rate_interval]))##{{pool}}
ts§12§Requêtes lentes§short§§sum by (pool) (increase(phpfpm_slow_requests{@SEL@}[$__rate_interval]))##{{pool}}
ts§12§File d'attente§short§§phpfpm_listen_queue{@SEL@}##{{pool}}
EOF
haproxy) cat <<'EOF' ;;
etat§6§HAProxy§§§up{@SEL@}
stat§6§Backends sans serveur§short§1,1§count(haproxy_backend_active_servers{@SEL@} + haproxy_backend_backup_servers{@SEL@} == 0) or vector(0)
stat§6§Serveurs DOWN§short§1,1§count(haproxy_server_status{@SEL@, state="DOWN"} == 1) or vector(0)
stat§6§Sessions en cours§short§§sum(haproxy_frontend_current_sessions{@SEL@})
ts§12§Requêtes par frontend§reqps§§sum by (proxy) (rate(haproxy_frontend_http_requests_total{@SEL@}[$__rate_interval]))##{{proxy}}
ts§12§Erreurs 5xx par backend§reqps§§sum by (proxy) (rate(haproxy_backend_http_responses_total{@SEL@, code="5xx"}[$__rate_interval]))##{{proxy}}
bargauge§12§Serveurs actifs par backend§short§§haproxy_backend_active_servers{@SEL@}##{{proxy}}
ts§12§Temps de réponse moyen des backends§s§§haproxy_backend_response_time_average_seconds{@SEL@}##{{proxy}}
EOF
rabbitmq) cat <<'EOF' ;;
etat§6§RabbitMQ§§§up{@SEL@}
stat§6§Messages prêts§short§@@SEUIL_RABBITMQ_MESSAGES@@,@@SEUIL_RABBITMQ_MESSAGES@@§sum(rabbitmq_queue_messages_ready{@SEL@})
stat§6§Messages non acquittés§short§@@SEUIL_RABBITMQ_MESSAGES@@,@@SEUIL_RABBITMQ_MESSAGES@@§sum(rabbitmq_queue_messages_unacked{@SEL@})
stat§6§Alarmes actives§short§1,1§sum(rabbitmq_alarms_memory_used_watermark{@SEL@}) + sum(rabbitmq_alarms_free_disk_space_watermark{@SEL@})
ts§12§Messages publiés et livrés§ops§§sum(rate(rabbitmq_global_messages_received_total{@SEL@}[$__rate_interval]))##publiés;;sum(rate(rabbitmq_global_messages_delivered_total{@SEL@}[$__rate_interval]))##livrés
ts§12§Messages en file§short§§sum(rabbitmq_queue_messages_ready{@SEL@})##prêts;;sum(rabbitmq_queue_messages_unacked{@SEL@})##non acquittés
ts§12§Connexions et consommateurs§short§§sum(rabbitmq_connections{@SEL@})##connexions;;sum(rabbitmq_queue_consumers{@SEL@})##consommateurs
ts§12§Mémoire par nœud§bytes§§rabbitmq_process_resident_memory_bytes{@SEL@}##{{instance}}
EOF
kafka) cat <<'EOF' ;;
stat§6§Brokers§short§§max(kafka_brokers{@SEL@})
stat§6§Topics§short§§count(count by (topic) (kafka_topic_partitions{@SEL@}))
stat§6§Partitions sous-répliquées§short§1,1§sum(kafka_topic_partition_under_replicated_partition{@SEL@})
stat§6§Retard total des consommateurs§short§@@SEUIL_KAFKA_LAG@@,@@SEUIL_KAFKA_LAG@@§sum(kafka_consumergroup_lag{@SEL@})
ts§12§Messages produits par topic§ops§§sum by (topic) (rate(kafka_topic_partition_current_offset{@SEL@}[$__rate_interval]))##{{topic}}
ts§12§Retard par groupe de consommateurs§short§@@SEUIL_KAFKA_LAG@@,@@SEUIL_KAFKA_LAG@@§sum by (consumergroup) (kafka_consumergroup_lag{@SEL@})##{{consumergroup}}
EOF
jvm) cat <<'EOF' ;;
etat§4§Application§§§up{@SEL@}
stat§4§Démarrée depuis§s§§time() - process_start_time_seconds{@SEL@}
gauge§4§Mémoire heap§percent§@@SEUIL_JVM_HEAP_PCT@@,95§sum(jvm_memory_used_bytes{@SEL@, area="heap"}) / sum(jvm_memory_max_bytes{@SEL@, area="heap"} > 0) * 100
stat§4§Threads§short§@@SEUIL_JVM_THREADS@@,@@SEUIL_JVM_THREADS@@§max(jvm_threads_current{@SEL@} or jvm_threads_live_threads{@SEL@})
stat§4§Erreurs HTTP 5xx§percent§@@SEUIL_HTTP_ERREURS_PCT@@,@@SEUIL_HTTP_ERREURS_PCT@@§sum(rate(http_server_requests_seconds_count{@SEL@, status=~"5.."}[5m])) / sum(rate(http_server_requests_seconds_count{@SEL@}[5m])) * 100
stat§4§Temps de réponse moyen§s§@@SEUIL_HTTP_LATENCE_S@@,@@SEUIL_HTTP_LATENCE_S@@§sum(rate(http_server_requests_seconds_sum{@SEL@}[5m])) / sum(rate(http_server_requests_seconds_count{@SEL@}[5m]))
ts§12§Mémoire heap§bytes§§sum(jvm_memory_used_bytes{@SEL@, area="heap"})##utilisée;;sum(jvm_memory_committed_bytes{@SEL@, area="heap"})##réservée;;sum(jvm_memory_max_bytes{@SEL@, area="heap"} > 0)##maximum
ts§12§Part du temps en GC§percentunit§§sum(rate(jvm_gc_collection_seconds_sum{@SEL@}[$__rate_interval])) or sum(rate(jvm_gc_pause_seconds_sum{@SEL@}[$__rate_interval]))##ramasse-miettes
ts§12§Requêtes HTTP par statut§reqps§§sum by (status) (rate(http_server_requests_seconds_count{@SEL@}[$__rate_interval]))##{{status}}
ts§12§Threads§short§§max(jvm_threads_current{@SEL@} or jvm_threads_live_threads{@SEL@})##threads
EOF
process) cat <<'EOF' ;;
bargauge§12§Instances par processus (0 = arrêté)§short§inv:1,1§namedprocess_namegroup_num_procs{@SEL@}##{{groupname}}
bargauge§12§Mémoire résidente§bytes§§namedprocess_namegroup_memory_bytes{@SEL@, memtype="resident"}##{{groupname}}
ts§12§Processeur par processus§percent§§sum by (groupname) (rate(namedprocess_namegroup_cpu_seconds_total{@SEL@}[$__rate_interval])) * 100##{{groupname}}
ts§12§Descripteurs de fichiers ouverts§short§§namedprocess_namegroup_open_filedesc{@SEL@}##{{groupname}}
EOF
docker) cat <<'EOF' ;;
stat§6§Conteneurs§short§§count(container_last_seen{@SEL@, name!=""})
stat§6§Arrêts par manque de mémoire (24 h)§short§1,1§sum(increase(container_oom_events_total{@SEL@, name!=""}[24h])) or vector(0)
bargauge§12§Mémoire par conteneur§bytes§§container_memory_working_set_bytes{@SEL@, name!=""}##{{name}}
ts§12§Processeur par conteneur (% d'un cœur)§percent§§sum by (name) (rate(container_cpu_usage_seconds_total{@SEL@, name!=""}[$__rate_interval])) * 100##{{name}}
ts§12§Réseau reçu par conteneur§bps§§sum by (name) (rate(container_network_receive_bytes_total{@SEL@, name!=""}[$__rate_interval])) * 8##{{name}}
EOF
application) cat <<'EOF' ;;
etat§6§Application§§§up{@SEL@}
stat§6§Démarrée depuis§s§§time() - process_start_time_seconds{@SEL@}
stat§6§Requêtes par seconde§reqps§§sum(rate(http_requests_total{@SEL@}[5m]))
stat§6§Erreurs HTTP 5xx§percent§@@SEUIL_HTTP_ERREURS_PCT@@,@@SEUIL_HTTP_ERREURS_PCT@@§sum(rate(http_requests_total{@SEL@, code=~"5.."}[5m])) / sum(rate(http_requests_total{@SEL@}[5m])) * 100
ts§12§Requêtes par code HTTP§reqps§§sum by (code) (rate(http_requests_total{@SEL@}[$__rate_interval]))##{{code}}
ts§12§Mémoire du processus§bytes§§process_resident_memory_bytes{@SEL@}##résidente
ts§12§Processeur§percent§§rate(process_cpu_seconds_total{@SEL@}[$__rate_interval]) * 100##processeur
ts§12§Descripteurs de fichiers§short§§process_open_fds{@SEL@}##ouverts;;process_max_fds{@SEL@}##maximum
EOF
    *) return 1 ;;
    esac
}

json_echap() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "${s}"; }

seuils_json() {
    local s="$1" a b
    if [[ -z "${s}" ]]; then
        echo '{"mode": "absolute", "steps": [{"color": "green", "value": null}]}'
    elif [[ "${s}" == inv:* ]]; then
        s="${s#inv:}"; a="${s%%,*}"; b="${s##*,}"
        echo "{\"mode\": \"absolute\", \"steps\": [{\"color\": \"red\", \"value\": null}, {\"color\": \"orange\", \"value\": ${a}}, {\"color\": \"green\", \"value\": ${b}}]}"
    else
        a="${s%%,*}"; b="${s##*,}"
        echo "{\"mode\": \"absolute\", \"steps\": [{\"color\": \"green\", \"value\": null}, {\"color\": \"orange\", \"value\": ${a}}, {\"color\": \"red\", \"value\": ${b}}]}"
    fi
}

# Construit le JSON Grafana d'un tableau de bord applicatif
tableau_app_json() {
    local tb="$1" ligne type larg titre unite seuils requetes
    tableau_meta "${tb}" || die "Tableau inconnu : ${tb}"
    local sel="job=~\"${TB_JOBS}\", instance=~\"\$instance\""
    local x=0 y=0 hligne=0 id=1 h panneaux="" premier=1
    while IFS= read -r ligne; do
        [[ -n "${ligne}" ]] || continue
        # Découpage manuel (sûr pour un séparateur multi-octets, quelle que soit la locale)
        type="${ligne%%§*}";   ligne="${ligne#*§}"
        larg="${ligne%%§*}";   ligne="${ligne#*§}"
        titre="${ligne%%§*}";  ligne="${ligne#*§}"
        unite="${ligne%%§*}";  ligne="${ligne#*§}"
        seuils="${ligne%%§*}"; requetes="${ligne#*§}"
        case "${type}" in ts|bargauge) h=8 ;; gauge) h=6 ;; *) h=4 ;; esac
        if (( x + larg > 24 )); then x=0; y=$((y + hligne)); hligne=0; fi
        # Requêtes
        local cibles="" r expr leg ref=A instant=false
        [[ "${type}" != ts ]] && instant=true
        IFS=';' read -ra _reqs <<<"${requetes//;;/;}"
        for r in "${_reqs[@]}"; do
            expr="${r%%##*}"; leg=""; [[ "${r}" == *"##"* ]] && leg="${r#*##}"
            expr="${expr//@SEL@/${sel}}"
            cibles+="${cibles:+, }{\"refId\": \"${ref}\", \"expr\": \"$(json_echap "${expr}")\", \"legendFormat\": \"$(json_echap "${leg}")\", \"instant\": ${instant}, \"range\": $([[ ${instant} == true ]] && echo false || echo true)}"
            ref="$(printf "\\$(printf '%03o' $(( $(printf '%d' "'${ref}") + 1 )))")"
        done
        # Options selon le type
        local gtype="${type}" options defaults minmax="" mappings=""
        case "${unite}" in percent) minmax=', "min": 0, "max": 100' ;; percentunit) minmax=', "min": 0, "max": 1' ;; esac
        case "${type}" in
            etat)    gtype=stat; mappings=', "mappings": [{"type": "value", "options": {"1": {"text": "OK", "color": "green", "index": 0}, "0": {"text": "EN PANNE", "color": "red", "index": 1}}}]'
                     seuils="" ;;
            couleur) gtype=stat; mappings=', "mappings": [{"type": "value", "options": {"0": {"text": "VERT", "color": "green", "index": 0}, "1": {"text": "JAUNE", "color": "yellow", "index": 1}, "2": {"text": "ROUGE", "color": "red", "index": 2}}}]' ;;
            ts)      gtype=timeseries ;;
        esac
        case "${gtype}" in
            stat)       options='{"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "'"$([[ "${type}" =~ ^(etat|couleur)$ ]] && echo background || echo value)"'", "graphMode": "none", "textMode": "value", "justifyMode": "center"}' ;;
            gauge)      options='{"reduceOptions": {"calcs": ["lastNotNull"]}, "showThresholdMarkers": true}' ;;
            bargauge)   options='{"reduceOptions": {"calcs": ["lastNotNull"]}, "orientation": "horizontal", "displayMode": "basic", "showUnfilled": true, "valueMode": "color", "namePlacement": "left"}' ;;
            timeseries) options='{"legend": {"displayMode": "list", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}}' ;;
        esac
        if [[ "${gtype}" == timeseries ]]; then
            defaults="{\"unit\": \"${unite:-short}\", \"noValue\": \"—\", \"color\": {\"mode\": \"palette-classic\"}, \"custom\": {\"lineWidth\": 2, \"fillOpacity\": 10, \"showPoints\": \"never\", \"thresholdsStyle\": {\"mode\": \"$([[ -n "${seuils}" ]] && echo dashed || echo off)\"}}, \"thresholds\": $(seuils_json "${seuils}")${minmax}}"
        else
            defaults="{\"unit\": \"${unite:-none}\", \"noValue\": \"—\", \"decimals\": $([[ "${unite}" =~ ^(percent|short|none|)$ ]] && echo 0 || echo 2), \"color\": {\"mode\": \"thresholds\"}, \"thresholds\": $(seuils_json "${seuils}")${minmax}${mappings}}"
        fi
        panneaux+="${premier:+}$([[ ${premier} -eq 1 ]] || echo ', ')
    {\"id\": ${id}, \"type\": \"${gtype}\", \"title\": \"$(json_echap "${titre}")\", \"gridPos\": {\"h\": ${h}, \"w\": ${larg}, \"x\": ${x}, \"y\": ${y}}, \"datasource\": ${DS_JSON},
     \"targets\": [${cibles}], \"options\": ${options}, \"fieldConfig\": {\"defaults\": ${defaults}, \"overrides\": []}}"
        premier=0; id=$((id + 1)); x=$((x + larg)); (( h > hligne )) && hligne=${h}
    done < <(tableau_spec "${tb}" | FS_FILTRE="${FS_FILTRE}" rendu)
    cat <<EOF
{
  "uid": "prometheus-bundle-${tb}",
  "title": "Supervision — $(json_echap "${TB_TITRE}")",
  "tags": ["prometheus-bundle", "${tb}"],
  "timezone": "browser", "editable": false, "graphTooltip": 1, "refresh": "1m", "schemaVersion": 39,
  "time": {"from": "now-6h", "to": "now"},
  "links": ${LIENS_JSON},
  "templating": {"list": [{
    "name": "instance", "label": "Instance", "type": "query", "datasource": ${DS_JSON},
    "query": {"query": "$(json_echap "${TB_VAR}")", "refId": "instance"}, "definition": "$(json_echap "${TB_VAR}")",
    "refresh": 2, "sort": 1, "includeAll": false, "multi": false}]},
  "panels": [${panneaux}
  ]
}
EOF
}

# --- Installation de Grafana -------------------------------------------------
grafana_installer_paquet() {
    local fam paquet
    fam="$(famille_os)"
    paquet="$(ls "${PACKAGES_DIR}"/grafana*.{deb,rpm} 2>/dev/null | head -n1)"
    if [[ -n "${paquet}" ]]; then
        log_info "Paquet local : ${paquet}"
        case "${paquet}" in
            *.deb) apt-get install -y "${paquet}" || dpkg -i "${paquet}" ;;
            *.rpm) if cmd_exists dnf; then dnf install -y "${paquet}"; else yum install -y "${paquet}"; fi ;;
        esac
        return $?
    fi
    [[ "${OFFLINE}" == yes ]] && die "Hors-ligne : déposer un paquet grafana*.deb ou grafana*.rpm dans packages/"
    case "${fam}" in
    debian)
        apt-get update -qq && apt-get install -y -qq apt-transport-https gnupg wget >/dev/null || return 1
        install -d -m 0755 /etc/apt/keyrings
        download https://apt.grafana.com/gpg.key "$(workdir)/grafana.key" || return 1
        gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg "$(workdir)/grafana.key" || return 1
        echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
        apt-get update -qq && apt-get install -y grafana ;;
    rhel)
        cat > /etc/yum.repos.d/grafana.repo <<'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF
        if cmd_exists dnf; then dnf install -y grafana; else yum install -y grafana; fi ;;
    *) die "Distribution non reconnue : installer Grafana manuellement puis relancer '${SCRIPT_NAME} 05 --sans-installation'" ;;
    esac
}

# URL de Prometheus utilisable depuis une autre machine
url_prometheus_publique() {
    if [[ ! "${GRAFANA_PROMETHEUS_URL}" =~ ://(127\.0\.0\.1|localhost)[:/] ]]; then
        echo "${GRAFANA_PROMETHEUS_URL}"; return
    fi
    [[ "${PROMETHEUS_LISTEN_ADDRESS}" =~ ^(127\.|localhost) ]] \
        && die "Prometheus n'écoute que sur ${PROMETHEUS_LISTEN_ADDRESS} : Grafana distant impossible (PROMETHEUS_LISTEN_ADDRESS=0.0.0.0)"
    echo "http://$(hostname -f 2>/dev/null || hostname):${PROMETHEUS_PORT}"
}

# Exécute « 05 <arguments> » sur la machine Grafana distante
grafana_distant() {
    local dest="${GRAFANA_HOTE_DISTANT}" url args
    cmd_exists ssh && cmd_exists scp || die "ssh et scp sont requis pour piloter Grafana à distance"
    url="$(url_prometheus_publique)" || exit 1
    # Un fichier à importer présent ici est copié sur la machine Grafana
    if [[ "${1:-}" == importer && -f "${2:-}" ]]; then
        scp -q "$2" "${dest}:/tmp/pb-import.json" || die "Copie de $2 impossible"
        set -- importer /tmp/pb-import.json "$(basename "$2" .json)"
    fi
    args="$(printf '%q ' "$@")"
    titre "Grafana sur ${dest} (Prometheus : ${url})"
    if prometheus_installe && [[ "${OPEN_FIREWALL}" == yes ]]; then ouvrir_port "${PROMETHEUS_PORT}" prometheus; fi
    scp -q "${SCRIPT_PATH}" "${dest}:/tmp/${SCRIPT_NAME}" || die "Copie SSH impossible vers ${dest}"
    ssh -t "${dest}" "sudo PB_GRAFANA_LOCAL=oui ASSUME_YES=${ASSUME_YES:-no} GRAFANA_PROMETHEUS_URL=$(printf '%q' "${url}") GRAFANA_PORT=${GRAFANA_PORT} OPEN_FIREWALL=${OPEN_FIREWALL} ${GRAFANA_ADMIN_PASSWORD:+GRAFANA_ADMIN_PASSWORD=$(printf '%q' "${GRAFANA_ADMIN_PASSWORD}")} bash /tmp/${SCRIPT_NAME} 05 ${args}; r=\$?; rm -f /tmp/${SCRIPT_NAME}; exit \$r"
}

# Applications réellement supervisées, lues dans Prometheus (local ou distant)
tableaux_detectes() {
    local jobs j
    jobs="$(http_get "${GRAFANA_PROMETHEUS_URL}/api/v1/label/job/values" 2>/dev/null \
            | grep -o '"data":\[[^]]*\]' | grep -o '"[^"]*"' | tr -d '"' | grep -v '^data$')"
    for j in ${jobs}; do
        [[ " ${TABLEAUX[*]} ${APPLICATIONS[*]} " == *" ${j} "* ]] || continue
        tableau_de_app "${j}"
    done | sort -u
}

tableaux_installes() {
    local f
    for f in "${GRAFANA_DASH_DIR}"/app-*.json; do
        [[ -f "${f}" ]] && { f="$(basename "${f}" .json)"; echo "${f#app-}"; }
    done
}

tableau_installer() {
    local tb="$1"
    tableau_meta "${tb}" || die "Tableau inconnu : ${tb} (voir : ${SCRIPT_NAME} 05 tableaux)"
    install -d -m 0755 -o grafana -g "$(grafana_groupe)" "${GRAFANA_DASH_DIR}"
    tableau_app_json "${tb}" | ecrire_fichier "${GRAFANA_DASH_DIR}/app-${tb}.json" "grafana:$(grafana_groupe)" 0644 || exit 1
    log_ok "Tableau « Supervision — ${TB_TITRE} » installé"
}

tableaux_lister() {
    titre "Tableaux de bord disponibles"
    local tb det inst
    det=" $(tableaux_detectes | tr '\n' ' ') "; inst=" $(tableaux_installes | tr '\n' ' ') "
    printf '   %-14s %-34s %-12s %s\n' "Nom" "Contenu" "Installé" "Application supervisée"
    for tb in "${TABLEAUX[@]}"; do
        tableau_meta "${tb}"
        printf '   %-14s %-34s %-12s %s\n' "${tb}" "${TB_TITRE}" \
            "$([[ "${inst}" == *" ${tb} "* ]] && echo "${C_G}oui${C_0}       " || echo "non")" \
            "$([[ "${det}" == *" ${tb} "* ]] && echo "${C_G}oui${C_0}" || echo "-")"
    done
    echo
    echo " Installer : ${SCRIPT_NAME} 05 tableau <nom...>   (ou 'auto' = toutes les applications supervisées)"
    echo " Tableau communautaire grafana.com : ${SCRIPT_NAME} 05 importer <id | fichier.json>"
}

# Importe un tableau communautaire (grafana.com) ou un fichier JSON exporté
tableau_importer() {
    local src="${1:-}" nom f
    set -- "${1:-}" "${2:-}"
    [[ -n "${src}" ]] || die "Usage : ${SCRIPT_NAME} 05 importer <id grafana.com | fichier.json>"
    f="$(workdir)/import.json"
    if [[ -f "${src}" ]]; then
        cp "${src}" "${f}"; nom="$(basename "${src}" .json)"
        [[ "${src}" == /tmp/pb-import.json ]] && { nom="${2:-fichier}"; rm -f "${src}"; }
    elif [[ "${src}" =~ ^[0-9]+$ ]]; then
        [[ "${OFFLINE}" == yes ]] && die "Hors-ligne : télécharger le JSON depuis grafana.com puis l'importer comme fichier"
        download "https://grafana.com/api/dashboards/${src}/revisions/latest/download" "${f}" \
            || die "Téléchargement impossible du tableau ${src} depuis grafana.com"
        nom="grafana-${src}"
    else
        die "Source invalide : ${src}"
    fi
    grep -q '"panels"' "${f}" || die "Le fichier n'est pas un tableau de bord Grafana"
    # Toutes les sources de données déclarées pointent vers le Prometheus du bundle
    sed -E -i 's/\$\{DS_[A-Za-z0-9_]+\}/prometheus-bundle/g' "${f}"
    install -d -m 0755 -o grafana -g "$(grafana_groupe)" "${GRAFANA_DASH_DIR}"
    ecrire_fichier "${GRAFANA_DASH_DIR}/import-${nom}.json" "grafana:$(grafana_groupe)" 0644 < "${f}"
    log_ok "Tableau importé : import-${nom}.json (dossier Supervision, visible sous une minute)"
}

grafana_configurer_base() {
    install -d -m 0755 "${GRAFANA_PROV_DIR}/datasources" "${GRAFANA_PROV_DIR}/dashboards"
    install -d -m 0755 -o grafana -g "$(grafana_groupe)" "${GRAFANA_DASH_DIR}"
    ecrire_fichier "${GRAFANA_PROV_DIR}/datasources/prometheus-bundle.yml" "root:$(grafana_groupe)" 0640 <<EOF
# ${MARQUEUR}
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus-bundle
    type: prometheus
    access: proxy
    url: ${GRAFANA_PROMETHEUS_URL}
    isDefault: true
    editable: false
    jsonData:
      timeInterval: ${PROMETHEUS_SCRAPE_INTERVAL}
EOF
    ecrire_fichier "${GRAFANA_PROV_DIR}/dashboards/prometheus-bundle.yml" "root:$(grafana_groupe)" 0640 <<EOF
# ${MARQUEUR}
apiVersion: 1
providers:
  - name: prometheus-bundle
    folder: Supervision
    type: file
    disableDeletion: true
    allowUiUpdates: false
    updateIntervalSeconds: 60
    options:
      path: ${GRAFANA_DASH_DIR}
EOF
    tableau_de_bord_json | ecrire_fichier "${GRAFANA_DASH_DIR}/vue-ensemble.json" "grafana:$(grafana_groupe)" 0644 || exit 1
    log_ok "Source de données (${GRAFANA_PROMETHEUS_URL}) et tableau « Vue d'ensemble » provisionnés"
}

# Détermine l'URL de Prometheus quand Grafana est sur une autre machine
grafana_url_prometheus() {
    if ! prometheus_installe && [[ "${GRAFANA_PROMETHEUS_URL}" =~ ://(127\.0\.0\.1|localhost)[:/] ]]; then
        if interactif; then
            local u; read -r -p "Prometheus n'est pas sur cette machine. URL de Prometheus (ex. http://supervision01:9090) : " u
            [[ -n "${u}" ]] || die "URL de Prometheus requise"
            GRAFANA_PROMETHEUS_URL="${u%/}"
            confirm "Enregistrer cette URL dans le script (GRAFANA_PROMETHEUS_URL) ?" && definir_parametre GRAFANA_PROMETHEUS_URL "${GRAFANA_PROMETHEUS_URL}"
        else
            die "Prometheus n'est pas sur cette machine : définir GRAFANA_PROMETHEUS_URL=http://<serveur>:9090"
        fi
    fi
    if url_ok "${GRAFANA_PROMETHEUS_URL}/-/ready"; then
        log_ok "Prometheus joignable : ${GRAFANA_PROMETHEUS_URL}"
    else
        log_warn "Prometheus injoignable depuis cette machine (${GRAFANA_PROMETHEUS_URL}) : vérifier le pare-feu du port ${PROMETHEUS_PORT}"
    fi
}

etape_05() {
    local action="${1:-installer}"
    [[ "${action}" == aide || "${action}" == -h || "${action}" == --help ]] && { cat <<EOF
05 — Grafana et tableaux de bord
  ${SCRIPT_NAME} 05                         installe et configure Grafana (+ propose les tableaux par application)
  ${SCRIPT_NAME} 05 --sans-installation     Grafana déjà présent : configure seulement
  ${SCRIPT_NAME} 05 tableaux                tableaux disponibles, installés, et applications détectées
  ${SCRIPT_NAME} 05 tableau <nom...|auto>   installe des tableaux par application (auto = selon les applications supervisées)
  ${SCRIPT_NAME} 05 retirer <nom>           retire un tableau
  ${SCRIPT_NAME} 05 actualiser              régénère tous les tableaux installés (après un changement de seuil)
  ${SCRIPT_NAME} 05 importer <id|fichier>   importe un tableau communautaire grafana.com ou un export JSON
  ${SCRIPT_NAME} 05 distant <user@machine>  installe/pilote Grafana sur une AUTRE machine (via SSH)

Grafana sur une autre machine :
  - depuis le serveur Prometheus : ${SCRIPT_NAME} 05 distant admin@grafana01
    (mémorise la machine : toutes les commandes « 05 ... » suivantes y sont exécutées)
  - ou directement sur la machine Grafana :
    GRAFANA_PROMETHEUS_URL=http://supervision01:9090 ${SCRIPT_NAME} 05
Machine Grafana actuelle : ${GRAFANA_HOTE_DISTANT:-cette machine}
EOF
        return 0; }

    # « 05 distant <machine> » : mémorise la machine puis y installe Grafana
    if [[ "${action}" == distant ]]; then
        [[ -n "${2:-}" ]] || die "Usage : ${SCRIPT_NAME} 05 distant <utilisateur@machine>  (ou 'local' pour revenir à cette machine)"
        require_root
        if [[ "$2" == local ]]; then definir_parametre GRAFANA_HOTE_DISTANT ""; return 0; fi
        definir_parametre GRAFANA_HOTE_DISTANT "$2"
        shift 2; set -- "${@:-installer}"; action="$1"
    fi
    # Grafana sur une autre machine : la commande y est relayée
    if [[ -n "${GRAFANA_HOTE_DISTANT}" && "${PB_GRAFANA_LOCAL:-non}" != oui ]]; then
        grafana_distant "$@"; return $?
    fi

    case "${action}" in
    tableaux) tableaux_lister; return 0 ;;
    tableau)
        require_root; shift
        [[ -d /usr/share/grafana ]] || die "Grafana n'est pas installé sur cette machine (étape 05)"
        local liste=("$@")
        if [[ ${#liste[@]} -eq 0 ]]; then
            tableaux_lister
            interactif || return 0
            local r; read -r -p "Tableaux à installer (noms séparés par des espaces, ou 'auto') : " r
            read -ra liste <<<"${r}"
        fi
        if [[ "${liste[*]}" == auto ]]; then mapfile -t liste < <(tableaux_detectes); fi
        (( ${#liste[@]} > 0 )) || { log_warn "Aucun tableau sélectionné (aucune application détectée ?)"; return 0; }
        local tb; for tb in "${liste[@]}"; do tableau_installer "$(tableau_de_app "${tb}")"; done
        return 0 ;;
    retirer)
        require_root
        [[ -n "${2:-}" ]] || die "Usage : ${SCRIPT_NAME} 05 retirer <nom>"
        rm -f "${GRAFANA_DASH_DIR}/app-$(tableau_de_app "$2").json" "${GRAFANA_DASH_DIR}/import-$2.json"
        log_ok "Tableau $2 retiré (disparaît de Grafana sous une minute)"; return 0 ;;
    actualiser)
        require_root
        grafana_configurer_base
        local tb; for tb in $(tableaux_installes); do tableau_installer "${tb}"; done
        return 0 ;;
    importer) require_root; tableau_importer "${2:-}" "${3:-}"; return $? ;;
    installer|--sans-installation) ;;
    *) die "Action inconnue : ${action} (voir : ${SCRIPT_NAME} 05 aide)" ;;
    esac

    require_root
    titre "05 - Grafana"
    if [[ ! -d /usr/share/grafana ]]; then
        [[ "${action}" != --sans-installation ]] || die "Grafana n'est pas installé"
        grafana_installer_paquet || die "Installation de Grafana impossible"
        log_ok "Grafana installé"
    else
        log_info "Grafana déjà présent : configuration uniquement"
    fi
    grafana_url_prometheus
    grafana_configurer_base

    install -d -m 0755 "${SYSTEMD_DIR}/grafana-server.service.d"
    ecrire_fichier "${SYSTEMD_DIR}/grafana-server.service.d/prometheus-bundle.conf" root:root 0644 <<EOF
# ${MARQUEUR}
[Service]
Environment=GF_SERVER_HTTP_PORT=${GRAFANA_PORT}
Environment=GF_USERS_DEFAULT_LANGUAGE=fr-FR
Environment=GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=${GRAFANA_DASH_DIR}/vue-ensemble.json
Environment=GF_ANALYTICS_REPORTING_ENABLED=false
Environment=GF_ANALYTICS_CHECK_FOR_UPDATES=false
Environment=GF_PLUGINS_PREINSTALL_DISABLED=true
EOF
    systemctl daemon-reload
    systemctl enable --quiet grafana-server
    systemctl restart grafana-server
    ouvrir_port "${GRAFANA_PORT}" grafana
    attendre_http "http://127.0.0.1:${GRAFANA_PORT}/api/health" 90 || die "Grafana ne démarre pas : journalctl -u grafana-server"
    log_ok "Grafana prêt : http://$(hostname -f 2>/dev/null || nom_hote):${GRAFANA_PORT}"

    # Mot de passe administrateur (premier démarrage : admin/admin)
    local mdp_fichier=/root/grafana-admin.txt mdp="${GRAFANA_ADMIN_PASSWORD}"
    [[ -n "${mdp}" ]] || mdp="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 20)"
    if cmd_exists curl && curl -fsS -u admin:admin -H 'Content-Type: application/json' -X PUT \
        -d "{\"oldPassword\":\"admin\",\"newPassword\":\"${mdp}\",\"confirmNew\":\"${mdp}\"}" \
        "http://127.0.0.1:${GRAFANA_PORT}/api/user/password" >/dev/null 2>&1; then
        ( umask 077; printf 'Grafana http://%s:%s\nutilisateur : admin\nmot de passe : %s\n' "$(nom_hote)" "${GRAFANA_PORT}" "${mdp}" > "${mdp_fichier}" )
        log_ok "Mot de passe admin défini : voir ${mdp_fichier} (sur $(nom_hote))"
    else
        log_info "Mot de passe admin déjà personnalisé (inchangé)"
    fi

    # Tableaux par application
    local det; det="$(tableaux_detectes | tr '\n' ' ')"
    if [[ -n "${det// /}" ]]; then
        log_info "Applications supervisées détectées : ${det}"
        if confirm "Installer les tableaux de bord dédiés à ces applications ?"; then
            local tb; for tb in ${det}; do tableau_installer "${tb}"; done
        else
            log_info "Plus tard : ${SCRIPT_NAME} 05 tableau auto"
        fi
    fi
}

# =============================================================================
#  06 — EXPLOITATION
# =============================================================================
etat_service() {
    local s="$1" e
    if ! systemctl list-unit-files "${s}.service" 2>/dev/null | grep -q "${s}"; then return; fi
    e="$(systemctl is-active "${s}" 2>/dev/null)"
    case "${e}" in
        active) printf '   %-28s %sACTIF%s\n' "${s}" "${C_G}" "${C_0}" ;;
        *)      printf '   %-28s %s%s%s\n' "${s}" "${C_R}" "${e^^}" "${C_0}" ;;
    esac
}

requete() { "${BIN_DIR}/promtool" query instant "$(prom_url)" "$1" 2>/dev/null | sed -n 's/.*=> \([0-9.e+-]*\) .*/\1/p' | head -n1; }

etape_06() {
    local action="${1:-etat}"; shift || true
    case "${action}" in
    etat)
        titre "État de la supervision — $(date '+%d/%m/%Y %H:%M')"
        echo " ${C_GRAS}Services${C_0}"
        local s f
        for s in prometheus alertmanager grafana-server; do etat_service "${s}"; done
        for f in "${SYSTEMD_DIR}"/*.service; do
            [[ -f "${f}" ]] && grep -q "${MARQUEUR} — agent" "${f}" && etat_service "$(basename "${f}" .service)"
        done
        if prometheus_installe && systemctl is-active --quiet prometheus 2>/dev/null; then
            echo; echo " ${C_GRAS}Cibles${C_0}"
            printf '   en ligne : %s   en panne : %s   sondes en échec : %s\n' \
                "$(requete 'count(up{job!~"http|tcp|icmp"} == 1) or vector(0)')" \
                "$(requete 'count(up{job!~"http|tcp|icmp"} == 0) or vector(0)')" \
                "$(requete 'count(probe_success == 0) or vector(0)')"
            echo; echo " ${C_GRAS}Alertes en cours${C_0}"
            printf '   critiques : %s   avertissements : %s\n' \
                "$(requete 'count(ALERTS{alertstate="firing",severity="critical"}) or vector(0)')" \
                "$(requete 'count(ALERTS{alertstate="firing",severity="warning"}) or vector(0)')"
            echo; echo " ${C_GRAS}Stockage${C_0}"
            printf '   données Prometheus : %s (rétention %s)\n' "$(du -sh "${PROMETHEUS_DATA_DIR}" 2>/dev/null | cut -f1)" "${PROMETHEUS_RETENTION_TIME}"
        fi
        echo ;;
    alertes)
        "${BIN_DIR}/amtool" alert query --alertmanager.url="$(am_url)" "$@" ;;
    silence)
        # 06 silence <serveur|matcher> [durée] [commentaire]
        [[ -n "${1:-}" ]] || die "Usage : ${SCRIPT_NAME} 06 silence <serveur | label=valeur> [durée, ex. 2h] [commentaire]"
        local m="$1" duree="${2:-2h}" com="${3:-Maintenance programmée}"
        [[ "${m}" == *[=~]* ]] || m="instance=~\"${m}.*\""
        "${BIN_DIR}/amtool" silence add "${m}" --duration="${duree}" --comment="${com}" \
            --author="${SUDO_USER:-$(whoami)}" --alertmanager.url="$(am_url)" \
            && log_ok "Alertes de ${m} mises en sourdine pour ${duree}" ;;
    silences)
        "${BIN_DIR}/amtool" silence query --alertmanager.url="$(am_url)" ;;
    lever)
        [[ -n "${1:-}" ]] || die "Usage : ${SCRIPT_NAME} 06 lever <id du silence | tous>"
        if [[ "$1" == tous ]]; then
            "${BIN_DIR}/amtool" silence query -q --alertmanager.url="$(am_url)" \
                | xargs -r "${BIN_DIR}/amtool" silence expire --alertmanager.url="$(am_url)"
        else
            "${BIN_DIR}/amtool" silence expire "$1" --alertmanager.url="$(am_url)"
        fi && log_ok "Silence levé" ;;
    recharger)
        require_root; recharger_prometheus; recharger_alertmanager ;;
    verifier)
        titre "Vérification des configurations"
        "${BIN_DIR}/promtool" check config "${PROMETHEUS_CONF_DIR}/prometheus.yml"
        "${BIN_DIR}/amtool" check-config "${ALERTMANAGER_CONF_DIR}/alertmanager.yml" ;;
    journaux)
        journalctl -u "${1:-prometheus}" -n "${2:-50}" --no-pager ;;
    *) cat <<EOF
06 — Exploitation
  ${SCRIPT_NAME} 06 etat                               services, cibles, alertes, stockage
  ${SCRIPT_NAME} 06 alertes                            alertes en cours (détail)
  ${SCRIPT_NAME} 06 silence <serveur> [2h] ["motif"]   maintenance : coupe les alertes d'un serveur
  ${SCRIPT_NAME} 06 silences                           maintenances en cours
  ${SCRIPT_NAME} 06 lever <id|tous>                    fin de maintenance
  ${SCRIPT_NAME} 06 recharger                          recharge Prometheus et Alertmanager
  ${SCRIPT_NAME} 06 verifier                           vérifie les configurations
  ${SCRIPT_NAME} 06 journaux [service] [lignes]        journaux systemd
EOF
        ;;
    esac
}

# =============================================================================
#  07 — SAUVEGARDE ET RESTAURATION
# =============================================================================
elements_a_sauvegarder() {
    local e
    for e in "${PROMETHEUS_CONF_DIR}" "${ALERTMANAGER_CONF_DIR}" "${EXPORTERS_CONF_DIR}" "${JMX_DIR}" \
             "${GRAFANA_PROV_DIR}/datasources/prometheus-bundle.yml" "${GRAFANA_PROV_DIR}/dashboards/prometheus-bundle.yml" \
             "${GRAFANA_DASH_DIR}" /var/lib/grafana/grafana.db /root/grafana-admin.txt "${SCRIPT_PATH}"; do
        [[ -e "${e}" ]] && echo "${e}"
    done
    for e in "${SYSTEMD_DIR}"/*.service "${SYSTEMD_DIR}"/grafana-server.service.d/prometheus-bundle.conf; do
        [[ -f "${e}" ]] && grep -q "${MARQUEUR}" "${e}" && echo "${e}"
    done
}

etape_07() {
    local action="${1:-sauvegarder}"; shift || true
    case "${action}" in
    sauvegarder)
        require_root
        install -d -m 0700 "${BACKUP_DIR}"
        local archive="${BACKUP_DIR}/prometheus-bundle_$(nom_hote)_$(date +%Y%m%d_%H%M%S).tar.gz"
        local liste; mapfile -t liste < <(elements_a_sauvegarder)
        (( ${#liste[@]} > 0 )) || die "Rien à sauvegarder"
        if [[ "${1:-}" == --donnees ]]; then
            log_info "Données incluses (copie à chaud, journal WAL exclu)"
            liste+=("${PROMETHEUS_DATA_DIR}" "${ALERTMANAGER_DATA_DIR}")
        fi
        tar -czPf "${archive}" --exclude="${PROMETHEUS_DATA_DIR}/wal" "${liste[@]}" 2>/dev/null \
            || [[ $? -eq 1 ]] || die "Échec de la sauvegarde"
        chmod 0600 "${archive}"
        log_ok "Sauvegarde : ${archive} ($(du -h "${archive}" | cut -f1))"
        # Rotation
        ls -1t "${BACKUP_DIR}"/prometheus-bundle_*.tar.gz 2>/dev/null | tail -n +"$((SAUVEGARDES_CONSERVEES + 1))" | xargs -r rm -f
        ;;
    liste)
        ls -lh "${BACKUP_DIR}"/prometheus-bundle_*.tar.gz 2>/dev/null || echo "Aucune sauvegarde dans ${BACKUP_DIR}" ;;
    restaurer)
        require_root
        local archive="${1:-}"
        [[ -n "${archive}" ]] || archive="$(ls -1t "${BACKUP_DIR}"/prometheus-bundle_*.tar.gz 2>/dev/null | head -n1)"
        [[ -f "${archive}" ]] || die "Archive introuvable : ${archive:-aucune}"
        echo "Contenu de ${archive} :"; tar -tzPf "${archive}" | awk -F/ 'NF<=5' | head -30
        confirm "Restaurer cette sauvegarde (les fichiers actuels seront remplacés) ?" || return 0
        local s; for s in prometheus alertmanager; do systemctl stop "${s}" 2>/dev/null; done
        tar -xzPf "${archive}" || die "Échec de la restauration"
        systemctl daemon-reload
        for s in alertmanager prometheus; do systemctl start "${s}" 2>/dev/null; done
        systemctl is-active --quiet grafana-server 2>/dev/null && systemctl restart grafana-server
        log_ok "Restauration terminée" ;;
    planifier)
        require_root
        echo "# ${MARQUEUR} — sauvegarde quotidienne
17 2 * * * root ${SCRIPT_PATH} 07 sauvegarder >/dev/null 2>&1" > /etc/cron.d/prometheus-bundle
        chmod 0644 /etc/cron.d/prometheus-bundle
        log_ok "Sauvegarde quotidienne planifiée à 02h17 (/etc/cron.d/prometheus-bundle)" ;;
    *) cat <<EOF
07 — Sauvegarde et restauration
  ${SCRIPT_NAME} 07 sauvegarder [--donnees]  configuration (+ données si --donnees)
  ${SCRIPT_NAME} 07 liste                    sauvegardes disponibles
  ${SCRIPT_NAME} 07 restaurer [archive]      restaure (la plus récente par défaut)
  ${SCRIPT_NAME} 07 planifier                sauvegarde automatique quotidienne
Répertoire : ${BACKUP_DIR} — ${SAUVEGARDES_CONSERVEES} archives conservées
EOF
        ;;
    esac
}

# =============================================================================
#  08 — TEST D'ALERTE PAR APPLICATION
# =============================================================================

# Règles d'une application, une par ligne : nom<TAB>sévérité<TAB>délai<TAB>expr<TAB>résumé<TAB>description
regles_tsv() {
    regles_generer "$1" | awk -v q="'" '
        function sortir() { if (nom != "") printf "%s\t%s\t%s\t%s\t%s\t%s\n", nom, sev, delai, expr, res, desc }
        /^ *- alert:/   { sortir(); nom=$3; sev=""; delai="immédiat"; expr=""; res=""; desc="" }
        /^ *expr:/      { sub("^ *expr: " q, ""); sub(q "$", ""); expr=$0 }
        /^ *for:/       { delai=$2 }
        /severity:/     { match($0, /severity: [a-z]+/); sev=substr($0, RSTART+10, RLENGTH-10) }
        /^ *summary:/   { sub(/^ *summary: "/, ""); sub(/"$/, ""); res=$0 }
        /^ *description:/ { sub(/^ *description: "/, ""); sub(/"$/, ""); desc=$0 }
        END { sortir() }'
}

# Métriques utilisées par une expression PromQL
metriques_expr() {
    sed -E 's/"[^"]*"//g; s/\{[^}]*\}//g; s/\[[^]]*\]//g;
            s/(by|without|on|ignoring|group_left|group_right) *\([^)]*\)//g' <<<"$1" \
        | grep -oE '[a-zA-Z_:][a-zA-Z0-9_:]*' \
        | grep -vxE 'by|without|on|ignoring|group_left|group_right|and|or|unless|offset|bool|sum|avg|min|max|count|topk|bottomk|stddev|quantile|rate|irate|increase|delta|idelta|changes|resets|deriv|predict_linear|abs|ceil|floor|round|clamp|clamp_max|clamp_min|scalar|vector|time|timestamp|absent|absent_over_time|label_replace|label_join|histogram_quantile|sort|sort_desc|(avg|min|max|sum|count|last|present|stddev|quantile)_over_time|e|inf|nan|humanize|printf' \
        | grep -E '_|^up$' | sort -u
}

# Valeurs d'exemple pour remplir les messages simulés
remplir_message() {
    local m="$1" app="$2" inst="$3"
    m="$(sed -E 's/\{\{ \$value[^}]*\}\}/42/g' <<<"${m}")"
    m="${m//\{\{ \$labels.instance \}\}/${inst}}"
    m="${m//\{\{ \$labels.job \}\}/${app}}"
    m="$(sed -E 's/\{\{ \$labels\.mountpoint \}\}/\/var/g; s/\{\{ \$labels\.device \}\}/sda/g;
                 s/\{\{ \$labels\.(name|groupname|server) \}\}/exemple/g; s/\{\{ \$labels\.datname \}\}/base_app/g;
                 s/\{\{ \$labels\.pool \}\}/www/g; s/\{\{ \$labels\.proxy \}\}/backend_web/g;
                 s/\{\{ \$labels\.topic \}\}/commandes/g; s/\{\{ \$labels\.consumergroup \}\}/facturation/g;
                 s/\{\{ \$labels\.volume \}\}/C:/g; s/\{\{ \$labels\.([a-z_]+) \}\}/\1-exemple/g' <<<"${m}")"
    printf '%s' "${m//\\\"/\"}"
}

# Canaux qui recevront une alerte de cette sévérité
canaux_pour() {
    local sev="$1" f noms=""
    for f in "${ALERTMANAGER_CONF_DIR}"/canaux.d/*.yml; do
        [[ -f "${f}" ]] || continue
        [[ "|$(awk -F': ' '/^# severites:/ {print $2}' "${f}")|" == *"|${sev}|"* ]] && noms+="$(basename "${f}" .yml) "
    done
    echo "${noms% }"
}

etape_08() {
    local app="" choix="" inst="" duree="5m" envoi=yes verif=yes
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --instance) inst="${2:-}"; shift ;;
            --duree) duree="${2:-5m}"; shift ;;
            --sans-envoi) envoi=no ;;
            --sans-verification) verif=no ;;
            aide|-h|--help) cat <<EOF
08 — Test d'alerte par application
  ${SCRIPT_NAME} 08 [application] [alerte|toutes|critiques] [options]
    application    clé du catalogue (linux, mysql, http...) ou 'base' ; menu si absente
    alerte         nom d'une règle, 'toutes', ou 'critiques' (défaut : choix dans un menu,
                   ou la première règle critique en mode non interactif)
    --instance X   instance simulée (défaut : première cible déclarée de l'application)
    --duree 5m     durée de l'alerte simulée ; à la fin, le message « RÉSOLU » est envoyé
    --sans-envoi   vérification des règles uniquement
    --sans-verification  envoi uniquement

Le test se fait en deux temps :
  1. Vérification : pour chaque règle, les métriques utilisées existent-elles dans Prometheus
     pour cette application ? (une règle dont la métrique manque ne se déclenchera jamais)
  2. Envoi : une alerte simulée, identique à la vraie (nom, gravité, message), libellée test="oui",
     part vers les canaux qui acceptent sa gravité.
Exemples :
  ${SCRIPT_NAME} 08 mysql
  ${SCRIPT_NAME} 08 linux HoteDisqueCritique --instance web01:9100
  ${SCRIPT_NAME} 08 redis critiques --duree 2m
EOF
                return 0 ;;
            *) if [[ -z "${app}" ]]; then app="$1"; elif [[ -z "${choix}" ]]; then choix="$1"; else die "Argument inattendu : $1"; fi ;;
        esac; shift
    done
    alertmanager_installe || die "À lancer sur le serveur Prometheus / Alertmanager"

    if [[ -z "${app}" ]]; then
        interactif || die "Préciser l'application : ${SCRIPT_NAME} 08 <application>"
        local actives; actives="$(applications_actives | tr '\n' ' ')"
        echo "Applications supervisées : ${actives:-aucune}"
        menu_applications; app="${MENU_APP}"
    fi
    local fichier jobre
    if [[ "${app}" == base ]]; then
        fichier=base; jobre="prometheus|alertmanager"
    else
        catalogue "${app}" || die "Application inconnue : ${app}"
        fichier="${APP_REGLES}"; jobre="${app}"
        [[ "${app}" == application ]] && jobre="application.*"
    fi
    [[ -z "${inst}" && -f "${PROMETHEUS_CONF_DIR}/targets/${app}.yml" ]] && \
        inst="$(grep -m1 -- '- targets:' "${PROMETHEUS_CONF_DIR}/targets/${app}.yml" | sed 's/.*\["\(.*\)"\].*/\1/')"
    inst="${inst:-test-${app}}"

    local -a lignes
    mapfile -t lignes < <(regles_tsv "${fichier}")
    # Pour les sondes, ne garder que les règles du type choisi
    if [[ "${fichier}" == sondes ]]; then
        local -a filtre=(); local l
        for l in "${lignes[@]}"; do
            [[ "${l}" == *"job=\"${app}\""* || "${l}" != *'job="'* ]] && filtre+=("${l}")
        done
        lignes=("${filtre[@]}")
    fi
    (( ${#lignes[@]} > 0 )) || die "Aucune règle pour ${app}"
    titre "08 - Test des alertes : ${app} (${#lignes[@]} règles, instance ${inst})"

    # --- 1. Vérification des métriques ---------------------------------------
    if [[ "${verif}" == yes ]]; then
        if prometheus_installe && url_ok "$(prom_url)/-/ready"; then
            local nb_cibles; nb_cibles="$(requete "count(up{job=~\"${jobre}\"}) or vector(0)")"
            [[ "${app}" == base ]] || log_info "Cibles ${app} collectées : ${nb_cibles:-0}"
            printf '\n   %-36s %-9s %-10s %s\n' "Règle" "Gravité" "Délai" "Vérification"
            local l nom sev delai expr m manquantes etat actives_n ok=0 ko=0 en_cours=0
            for l in "${lignes[@]}"; do
                IFS=$'\t' read -r nom sev delai expr _ _ <<<"${l}"
                manquantes=""
                for m in $(metriques_expr "${expr}"); do
                    [[ "${m}" == up ]] && continue
                    [[ "$(requete "count(${m}{job=~\"${jobre}\"}) or vector(0)")" =~ ^0?$ ]] && manquantes+="${m} "
                done
                actives_n="$(requete "count(ALERTS{alertname=\"${nom}\",alertstate=\"firing\"}) or vector(0)")"
                if [[ -n "${manquantes}" ]]; then
                    etat="${C_Y}métrique absente : ${manquantes% }${C_0}"; ko=$((ko + 1))
                else
                    etat="${C_G}opérationnelle${C_0}"; ok=$((ok + 1))
                fi
                [[ "${actives_n}" =~ ^[1-9] ]] && { etat+=" ${C_R}— EN COURS (${actives_n})${C_0}"; en_cours=1; }
                printf '   %-36s %-9s %-10s %s\n' "${nom}" "${sev}" "${delai}" "${etat}"
            done
            echo
            log_info "${ok} règle(s) opérationnelle(s), ${ko} dont une métrique est absente"
            (( ko > 0 && en_cours )) && log_warn "Une alerte est en cours : si l'application est arrêtée, son agent n'expose plus ses autres métriques (normal)"
            (( ko > 0 )) && log_info "Métrique absente : application non déclarée, agent sans accès, fonctionnalité non utilisée (ex. réplication) ou version d'agent différente"
        else
            log_warn "Prometheus non joignable ici : vérification des métriques ignorée"
        fi
    fi
    [[ "${envoi}" == yes ]] || return 0

    # --- 2. Choix des alertes à simuler --------------------------------------
    local -a envoyer=()
    case "${choix}" in
        toutes) envoyer=("${lignes[@]}") ;;
        critiques) local l; for l in "${lignes[@]}"; do [[ "$(cut -f2 <<<"${l}")" == critical ]] && envoyer+=("${l}"); done ;;
        "")
            if interactif; then
                local i=1 l; echo "Alerte à simuler :"
                for l in "${lignes[@]}"; do printf '  %2d) %-36s %s\n' "${i}" "$(cut -f1 <<<"${l}")" "$(cut -f2 <<<"${l}")"; i=$((i + 1)); done
                local r; read -r -p "Numéro (Entrée = première critique, 't' = toutes) : " r
                if [[ "${r}" == t ]]; then envoyer=("${lignes[@]}")
                elif [[ "${r}" =~ ^[0-9]+$ ]] && (( r >= 1 && r <= ${#lignes[@]} )); then envoyer=("${lignes[$((r - 1))]}"); fi
            fi
            if (( ${#envoyer[@]} == 0 )); then
                local l; for l in "${lignes[@]}"; do [[ "$(cut -f2 <<<"${l}")" == critical ]] && { envoyer=("${l}"); break; }; done
                (( ${#envoyer[@]} )) || envoyer=("${lignes[0]}")
            fi ;;
        *) local l; for l in "${lignes[@]}"; do [[ "$(cut -f1 <<<"${l}")" == "${choix}" ]] && envoyer=("${l}"); done
           (( ${#envoyer[@]} )) || die "Règle inconnue pour ${app} : ${choix} (voir : ${SCRIPT_NAME} 02 regles ${app})" ;;
    esac

    # --- 3. Envoi ----------------------------------------------------------------
    titre "Envoi des alertes simulées (durée ${duree})"
    local fin s; s="${duree%[smh]}"
    case "${duree}" in *h) s=$((s * 3600)) ;; *m) s=$((s * 60)) ;; esac
    fin="$(date -u -d "+${s} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    local l nom sev res desc cat canaux envoyees=0
    for l in "${envoyer[@]}"; do
        IFS=$'\t' read -r nom sev _ _ res desc <<<"${l}"
        cat="$(regles_generer "${fichier}" | awk -v n="${nom}" '$0 ~ "- alert: "n"$" {t=1} t && /categorie:/ {match($0, /categorie: [a-z-]+/); print substr($0, RSTART+11, RLENGTH-11); exit}')"
        canaux="$(canaux_pour "${sev}")"
        if "${BIN_DIR}/amtool" alert add "${nom}" severity="${sev}" categorie="${cat:-test}" job="${app}" instance="${inst}" test="oui" \
            --annotation=summary="[TEST] $(remplir_message "${res}" "${app}" "${inst}")" \
            --annotation=description="$(remplir_message "${desc}" "${app}" "${inst}") — Alerte simulée par ${SCRIPT_NAME} 08, aucune action requise." \
            ${fin:+--end="${fin}"} --alertmanager.url="$(am_url)" >/dev/null 2>&1; then
            envoyees=$((envoyees + 1))
            if [[ -n "${canaux}" ]]; then
                log_ok "${nom} (${sev}) → ${canaux}"
            else
                log_warn "${nom} (${sev}) → aucun canal n'accepte la gravité '${sev}' (visible seulement dans Alertmanager)"
            fi
        else
            log_error "Envoi impossible : ${nom}"
        fi
    done
    echo
    log_info "${envoyees} alerte(s) simulée(s) envoyée(s) : réception sous ${ALERT_GROUP_WAIT}, message « RÉSOLU » après ${duree}"
    log_info "Les alertes simulées portent le libellé test=\"oui\" et le préfixe [TEST]."
    log_info "Faire taire un test en cours : ${SCRIPT_NAME} 06 silence 'test=\"oui\"' ${duree} \"fin de test\""
}

# =============================================================================
#  99 — NETTOYAGE
# =============================================================================
etape_99() {
    local backup=no keep_data=no keep_config=no keep_users=no grafana=no
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) ASSUME_YES=yes ;; --backup) backup=yes ;;
            --keep-data) keep_data=yes ;; --keep-config) keep_config=yes ;;
            --keep-users) keep_users=yes ;; --grafana) grafana=yes ;;
            aide|-h|--help) cat <<EOF
99 — Nettoyage d'une installation précédente
  ${SCRIPT_NAME} 99 [-y] [--backup] [--keep-data] [--keep-config] [--keep-users] [--grafana]
    -y            sans confirmation
    --backup      sauvegarde (étape 07, avec données) avant suppression
    --keep-data   conserve les données (TSDB, silences)
    --keep-config conserve les configurations
    --keep-users  conserve les comptes système
    --grafana     désinstalle aussi le paquet Grafana (sinon seule sa configuration bundle est retirée)
Fonctionne aussi sur un serveur ne portant que des agents.
EOF
                return 0 ;;
            *) die "Option inconnue : $1" ;;
        esac; shift
    done
    require_root
    titre "99 - Nettoyage"
    for d in "${PROMETHEUS_CONF_DIR}" "${PROMETHEUS_DATA_DIR}" "${ALERTMANAGER_CONF_DIR}" \
             "${ALERTMANAGER_DATA_DIR}" "${EXPORTERS_CONF_DIR}" "${JMX_DIR}"; do
        case "${d%/}" in ""|/|/etc|/var|/var/lib|/usr|/usr/local|/opt|/home|/root|/bin|/sbin)
            die "Chemin refusé : '${d}'" ;; esac
    done

    local unites=() f
    for f in "${SYSTEMD_DIR}"/*.service; do
        [[ -f "${f}" ]] && grep -q "${MARQUEUR}" "${f}" && unites+=("$(basename "${f}" .service)")
    done
    echo "Éléments ciblés :"
    (( ${#unites[@]} )) && echo "  - services : ${unites[*]}"
    for f in "${PROMETHEUS_CONF_DIR}" "${ALERTMANAGER_CONF_DIR}" "${EXPORTERS_CONF_DIR}" "${JMX_DIR}"; do
        [[ -d "${f}" && "${keep_config}" == no ]] && echo "  - ${f}/"
    done
    for f in "${PROMETHEUS_DATA_DIR}" "${ALERTMANAGER_DATA_DIR}"; do
        [[ -d "${f}" && "${keep_data}" == no ]] && echo "  - ${f}/ (données, $(du -sh "${f}" 2>/dev/null | cut -f1))"
    done
    [[ -f "${GRAFANA_PROV_DIR}/dashboards/prometheus-bundle.yml" ]] && echo "  - configuration Grafana du bundle"
    [[ "${grafana}" == yes ]] && echo "  - paquet Grafana et ses données"
    echo
    confirm "Confirmer la suppression définitive ?" || { log_info "Nettoyage annulé"; return 0; }

    [[ "${backup}" == yes ]] && etape_07 sauvegarder --donnees

    titre "Services"
    local u
    for u in "${unites[@]}"; do
        systemctl disable --now --quiet "${u}" 2>/dev/null
        rm -f "${SYSTEMD_DIR}/${u}.service"; rm -rf "${SYSTEMD_DIR}/${u}.service.d"
        log_ok "Service supprimé : ${u}"
    done
    for u in prometheus alertmanager; do pkill -x "${u}" 2>/dev/null || true; done

    titre "Binaires et fichiers"
    local b
    for b in prometheus promtool alertmanager amtool node_exporter blackbox_exporter mysqld_exporter \
             postgres_exporter redis_exporter mongodb_exporter memcached_exporter elasticsearch_exporter \
             nginx-prometheus-exporter apache_exporter php-fpm_exporter kafka_exporter process-exporter; do
        [[ -f "${BIN_DIR}/${b}" ]] && rm -f "${BIN_DIR}/${b}" && log_ok "Supprimé : ${BIN_DIR}/${b}"
    done
    if [[ "${keep_config}" == no ]]; then
        rm -rf "${PROMETHEUS_CONF_DIR}" "${ALERTMANAGER_CONF_DIR}" "${EXPORTERS_CONF_DIR}" "${JMX_DIR}"
        log_ok "Configurations supprimées"
    fi
    if [[ "${keep_data}" == no ]]; then
        rm -rf "${PROMETHEUS_DATA_DIR}" "${ALERTMANAGER_DATA_DIR}" /var/lib/node_exporter
        log_ok "Données supprimées"
    fi
    rm -f /etc/cron.d/prometheus-bundle

    titre "Grafana"
    [[ -n "${GRAFANA_HOTE_DISTANT}" ]] && log_info "Grafana est sur ${GRAFANA_HOTE_DISTANT} : y lancer « ${SCRIPT_NAME} 99 » pour le nettoyer"
    rm -f "${GRAFANA_PROV_DIR}/datasources/prometheus-bundle.yml" "${GRAFANA_PROV_DIR}/dashboards/prometheus-bundle.yml"
    rm -rf "${GRAFANA_DASH_DIR}" "${SYSTEMD_DIR}/grafana-server.service.d/prometheus-bundle.conf"
    if [[ "${grafana}" == yes ]]; then
        systemctl disable --now grafana-server 2>/dev/null
        if cmd_exists apt-get; then apt-get purge -y grafana >/dev/null 2>&1; rm -f /etc/apt/sources.list.d/grafana.list
        elif cmd_exists dnf; then dnf remove -y grafana >/dev/null 2>&1; rm -f /etc/yum.repos.d/grafana.repo
        elif cmd_exists yum; then yum remove -y grafana >/dev/null 2>&1; rm -f /etc/yum.repos.d/grafana.repo; fi
        rm -rf /var/lib/grafana /etc/grafana /root/grafana-admin.txt
        log_ok "Grafana désinstallé"
    elif systemctl is-active --quiet grafana-server 2>/dev/null; then
        systemctl daemon-reload; systemctl restart grafana-server
        log_ok "Configuration Grafana du bundle retirée"
    fi
    systemctl daemon-reload 2>/dev/null || true

    titre "Pare-feu"
    local p
    for p in "${PROMETHEUS_PORT}" "${ALERTMANAGER_PORT}" 9100 9104 9113 9114 9115 9117 9121 9150 9187 9216 9253 9256 9308; do
        fermer_port "${p}"
    done
    [[ "${grafana}" == yes ]] && fermer_port "${GRAFANA_PORT}"

    if [[ "${keep_users}" == no ]]; then
        titre "Comptes"
        for u in "${PROMETHEUS_USER}" "${ALERTMANAGER_USER}" "${EXPORTER_USER}"; do
            getent passwd "${u}" >/dev/null && userdel "${u}" && log_ok "Compte supprimé : ${u}"
            getent group "${u}" >/dev/null && groupdel "${u}" 2>/dev/null
        done
    fi
    titre "Bilan"
    log_ok "Nettoyage terminé : le serveur est prêt pour une nouvelle installation."
}

# =============================================================================
#  MENU ET POINT D'ENTRÉE
# =============================================================================
menu() {
    while true; do
        cat <<EOF

${C_GRAS}=== PROMETHEUS-BUNDLE — supervision applicative ===${C_0}
  00  Vérification préliminaire
  01  Installation Prometheus + Alertmanager
  02  Configuration (paramètres, seuils, règles)
  03  Agents et applications
  04  Canaux d'alerte (Slack, Teams, Telegram, e-mail, SMS...)
  05  Grafana + tableaux de bord (local ou autre machine)
  06  Exploitation (état, alertes, maintenance)
  07  Sauvegarde / restauration
  08  Test des alertes d'une application
  99  Nettoyage
  q   Quitter
EOF
        local c a; read -r -p "Choix : " c || return 0
        case "${c}" in
            00) etape_00 ;;
            01) etape_01 ;;
            02) etape_02 afficher; read -r -p "Action (definir VAR valeur | appliquer | regles | Entrée) : " a
                [[ -n "${a}" ]] && eval "etape_02 ${a}" ;;
            03) etape_03 aide; read -r -p "Action (catalogue | agent | cible | liste | retirer app adr | ...) : " a
                [[ -n "${a}" ]] && eval "etape_03 ${a}" ;;
            04) canaux_lister; read -r -p "Action (ajouter | supprimer nom | tester | types) : " a
                [[ -n "${a}" ]] && eval "etape_04 ${a}" ;;
            05) etape_05 ;;
            06) etape_06 etat; read -r -p "Action (alertes | silence srv 2h | silences | lever id | recharger) : " a
                [[ -n "${a}" ]] && eval "etape_06 ${a}" ;;
            07) etape_07 aide; read -r -p "Action (sauvegarder | liste | restaurer | planifier) : " a
                [[ -n "${a}" ]] && eval "etape_07 ${a}" ;;
            08) etape_08 ;;
            99) etape_99 ;;
            q|Q|"") return 0 ;;
            *) log_warn "Choix inconnu : ${c}" ;;
        esac
    done
}

main() {
    workdir >/dev/null
    local etape="${1:-}"; shift || true
    case "${etape}" in
        00|verification)  init_log 00_verification; etape_00 "$@" ;;
        01|installation)  init_log 01_installation; etape_01 "$@" ;;
        02|configuration) etape_02 "$@" ;;
        03|agents)        [[ "${1:-}" =~ ^(agent|cible|retirer|deployer|desinstaller)$ ]] && init_log 03_agents; etape_03 "$@" ;;
        04|alerting)      [[ "${1:-}" =~ ^(ajouter|supprimer)$ ]] && init_log 04_alerting; etape_04 "$@" ;;
        05|grafana)       [[ "${1:-}" =~ ^(aide|-h|--help|tableaux)$ ]] || init_log 05_grafana; etape_05 "$@" ;;
        06|exploitation)  etape_06 "$@" ;;
        07|sauvegarde)    etape_07 "$@" ;;
        08|test)          [[ "${1:-}" =~ ^(aide|-h|--help)$ ]] || init_log 08_test; etape_08 "$@" ;;
        99|nettoyage)     init_log 99_nettoyage; etape_99 "$@" ;;
        "")               if [[ -t 0 ]]; then menu; else sed -n '3,27p' "${SCRIPT_PATH}" | sed 's/^# \{0,2\}//'; fi ;;
        -h|--help|aide)   sed -n '3,27p' "${SCRIPT_PATH}" | sed 's/^# \{0,2\}//' ;;
        *) die "Étape inconnue : ${etape} (voir : ${SCRIPT_NAME} aide)" ;;
    esac
}

main "$@"
