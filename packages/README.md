# packages/ — installation hors-ligne

Si un fichier attendu est présent ici, `prometheus-bundle.sh` l'utilise au lieu de le télécharger.
Avec `OFFLINE=yes`, aucun accès Internet n'est tenté.

Déposer les fichiers **sous leur nom d'origine** (architecture du serveur cible, ex. `linux-amd64`) :

| Composant | Fichier | Sommes de contrôle |
|---|---|---|
| Prometheus | `prometheus-<v>.linux-amd64.tar.gz` | `sha256sums.txt` de la release |
| Alertmanager | `alertmanager-<v>.linux-amd64.tar.gz` | `sha256sums.txt` de la release |
| Agents | `node_exporter-<v>.linux-amd64.tar.gz`, `mysqld_exporter-...`, etc. | idem |
| Agent Java | `jmx_prometheus_javaagent-<v>.jar` | `jmx_prometheus_javaagent-<v>.jar.sha256` |
| Grafana | `grafana_<v>_amd64.deb` ou `grafana-<v>.x86_64.rpm` | — |

Plusieurs projets publient tous un fichier nommé `sha256sums.txt` : en mode hors-ligne, les fusionner en un seul
`sha256sums.txt` (`cat */sha256sums.txt > sha256sums.txt`), ou désactiver la vérification avec `VERIFY_CHECKSUM=no`.

Les versions et URL exactes sont en tête de `prometheus-bundle.sh` (section CONFIGURATION) et visibles avec :
`./prometheus-bundle.sh 02 afficher`.
