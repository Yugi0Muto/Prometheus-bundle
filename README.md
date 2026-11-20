# Prometheus-bundle

Bundle d'installation et de configuration de **Prometheus** et **Alertmanager**
sur un serveur Linux avec systemd (RHEL/Rocky/Alma, Debian/Ubuntu…).

| Script | Rôle |
|---|---|
| `00_verification_prealable.sh` | Vérifie que la machine est prête. Ne modifie rien. |
| `01_installation.sh` | Installe, configure, démarre et contrôle les deux services. |
| `99_nettoyage.sh` | Supprime une installation précédente (services, binaires, config, données, comptes, pare-feu). |

## Utilisation rapide

```bash
sudo ./00_verification_prealable.sh
```

```bash
sudo ./01_installation.sh
```

Pour repartir de zéro :

```bash
sudo ./99_nettoyage.sh --backup
```

Toute la configuration se trouve dans `config/bundle.conf`. Chaque variable peut
aussi être passée par l'environnement :

```bash
sudo PROMETHEUS_PORT=9091 ALERTMANAGER_RECEIVER_TYPE=email ALERTMANAGER_EMAIL_TO=ops@exemple.fr ./01_installation.sh
```

## Arborescence

```
config/bundle.conf              Versions, chemins, ports, comptes, récepteur d'alertes
lib/common.sh                   Fonctions communes (journalisation, détection, gabarits)
templates/prometheus.yml.tpl    Configuration Prometheus
templates/alertmanager-*.yml.tpl Configuration Alertmanager (webhook ou email)
templates/rules/*.yml           Règles d'alerte copiées dans /etc/prometheus/rules/
templates/systemd/*.service.tpl Unités systemd (avec durcissement)
packages/                       Archives pour installation hors-ligne
```

Les gabarits utilisent la syntaxe `@@VARIABLE@@`, remplacée par la valeur de la
variable de `bundle.conf`.

## 00 — Vérification préliminaire

Contrôles : droits root, Linux + systemd, architecture, commandes requises,
mémoire, espace disque, disponibilité des ports, installation existante,
présence ou téléchargeabilité des archives, état SELinux et pare-feu.
Code retour `0` si prêt (avertissements possibles), `1` en cas d'erreur.
Il est relancé automatiquement par `01_installation.sh`.

## 01 — Installation

1. Vérifications préliminaires (`--skip-checks` pour les ignorer)
2. Récupération des archives (`packages/` sinon GitHub) et **vérification SHA256**
3. Création des comptes système `prometheus` et `alertmanager` (sans shell)
4. Création de l'arborescence (`/etc/…`, `/var/lib/…`)
5. Installation des binaires `prometheus`, `promtool`, `alertmanager`, `amtool`
6. Déploiement des configurations, validées par `promtool` et `amtool`
7. Unités systemd, restauration SELinux, activation au démarrage
8. Ouverture du pare-feu si `OPEN_FIREWALL=yes` (firewalld ou ufw)
9. Démarrage puis contrôle de santé sur `/-/ready`

Options : `--force` (mise à jour : écrase binaires et configurations après
sauvegarde `.bak.<date>`), `--skip-checks`, `--no-start`.

Sans `--force`, le script refuse d'écraser une installation existante et ne
remplace jamais une configuration déjà présente.

## 99 — Nettoyage

Demande confirmation puis supprime : services et unités systemd, binaires,
configurations, données, règles de pare-feu et comptes système.

Options : `-y/--yes` (non interactif), `--backup` (archive dans
`/var/backups/prometheus-bundle/`), `--keep-data`, `--keep-config`, `--keep-users`.

## Installation hors-ligne

Déposez les archives et les fichiers de sommes dans `packages/` (voir
`packages/README.md`), puis :

```bash
sudo OFFLINE=yes ./01_installation.sh
```

## Journaux

Chaque exécution écrit un journal horodaté dans `/var/log/prometheus-bundle/`.
Les services se consultent avec `journalctl -u prometheus -u alertmanager`.
