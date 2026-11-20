[Unit]
Description=Prometheus Alertmanager - routage et notification des alertes
Documentation=https://prometheus.io/docs/alerting/latest/alertmanager/
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=@@ALERTMANAGER_USER@@
Group=@@ALERTMANAGER_GROUP@@
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

# Durcissement
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=@@ALERTMANAGER_DATA_DIR@@

[Install]
WantedBy=multi-user.target
