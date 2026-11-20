# =============================================================================
#  Alertmanager - configuration générée par Prometheus-bundle (récepteur e-mail)
#  Fichier : @@ALERTMANAGER_CONF_DIR@@/alertmanager.yml
#  Validation : amtool check-config @@ALERTMANAGER_CONF_DIR@@/alertmanager.yml
#  Rechargement : systemctl reload alertmanager
# =============================================================================
global:
  smtp_smarthost: "@@ALERTMANAGER_SMTP_SMARTHOST@@"
  smtp_from: "@@ALERTMANAGER_SMTP_FROM@@"
  smtp_require_tls: false
  # smtp_auth_username: ""
  # smtp_auth_password: ""

route:
  receiver: "defaut"
  group_by: ["alertname", "cluster", "instance"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: "defaut"
    email_configs:
      - to: "@@ALERTMANAGER_EMAIL_TO@@"
        send_resolved: true

inhibit_rules:
  - source_matchers: ['severity="critical"']
    target_matchers: ['severity="warning"']
    equal: ["alertname", "instance"]
