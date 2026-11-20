[Unit]
Description=Prometheus - supervision et base de séries temporelles
Documentation=https://prometheus.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=@@PROMETHEUS_USER@@
Group=@@PROMETHEUS_GROUP@@
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
TimeoutStopSec=60s
LimitNOFILE=65536

# Durcissement
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=@@PROMETHEUS_DATA_DIR@@

[Install]
WantedBy=multi-user.target
