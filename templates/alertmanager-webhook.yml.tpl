# =============================================================================
#  Alertmanager - configuration générée par Prometheus-bundle (récepteur webhook)
#  Fichier : @@ALERTMANAGER_CONF_DIR@@/alertmanager.yml
#  Validation : amtool check-config @@ALERTMANAGER_CONF_DIR@@/alertmanager.yml
#  Rechargement : systemctl reload alertmanager
# =============================================================================
route:
  receiver: "defaut"
  group_by: ["alertname", "cluster", "instance"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: "defaut"
    webhook_configs:
      - url: "@@ALERTMANAGER_WEBHOOK_URL@@"
        send_resolved: true

inhibit_rules:
  # Une alerte "critical" masque l'alerte "warning" équivalente
  - source_matchers: ['severity="critical"']
    target_matchers: ['severity="warning"']
    equal: ["alertname", "instance"]
