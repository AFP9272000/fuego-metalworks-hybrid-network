#!/bin/bash
echo "Fuego Metalworks order database (demo listener)" > /root/index.html
cat > /etc/systemd/system/dbdemo.service <<'UNIT'
[Unit]
Description=Fuego demo DB listener
After=network-online.target
[Service]
ExecStart=/usr/bin/python3 -m http.server 3306 --directory /root
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now dbdemo.service
