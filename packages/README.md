# packages/ — archives pour installation hors-ligne

Déposez ici les archives officielles (même architecture que la cible) :

```
prometheus-<version>.linux-<arch>.tar.gz
alertmanager-<version>.linux-<arch>.tar.gz
prometheus-sha256sums.txt      # = sha256sums.txt de la release Prometheus, renommé
alertmanager-sha256sums.txt    # = sha256sums.txt de la release Alertmanager, renommé
```

Sources : https://github.com/prometheus/prometheus/releases et
https://github.com/prometheus/alertmanager/releases

Si une archive est présente ici, elle est utilisée en priorité ; sinon elle est
téléchargée (sauf si `OFFLINE=yes`).
