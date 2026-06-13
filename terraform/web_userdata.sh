#!/bin/bash
echo "Fuego Metalworks order portal (demo)" > /root/index.html
cat > /etc/systemd/system/portal.service <<'UNIT'
[Unit]
Description=Fuego demo web portal
After=network-online.target
[Service]
ExecStart=/usr/bin/python3 -m http.server 80 --directory /root
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now portal.service
