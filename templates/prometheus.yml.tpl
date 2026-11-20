# =============================================================================
#  Prometheus - configuration générée par Prometheus-bundle
#  Fichier : @@PROMETHEUS_CONF_DIR@@/prometheus.yml
#  Validation : promtool check config @@PROMETHEUS_CONF_DIR@@/prometheus.yml
#  Rechargement : systemctl reload prometheus
# =============================================================================
global:
  scrape_interval: @@PROMETHEUS_SCRAPE_INTERVAL@@
  evaluation_interval: @@PROMETHEUS_EVALUATION_INTERVAL@@
  external_labels:
    cluster: "@@PROMETHEUS_CLUSTER_LABEL@@"

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - "@@ALERTMANAGER_TARGET@@"

rule_files:
  - "@@PROMETHEUS_CONF_DIR@@/rules/*.yml"

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["@@PROMETHEUS_TARGET@@"]

  - job_name: "alertmanager"
    static_configs:
      - targets: ["@@ALERTMANAGER_TARGET@@"]

  # Exemple : ajoutez vos node_exporter ici
  # - job_name: "node"
  #   static_configs:
  #     - targets: ["serveur1:9100", "serveur2:9100"]
