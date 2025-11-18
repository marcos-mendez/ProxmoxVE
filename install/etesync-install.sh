#!/usr/bin/env bash
# Copyright (c) 2021-2025 Community-Scripts ORG
# Author: Marcos Mendez / POP.COOP
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/etesync/server

# FUNCTIONS_FILE_PATH é injetado pelo build.func
source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"

color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing dependencies (Docker engine)"
$STD apt-get install -y docker.io ca-certificates
msg_ok "Installed dependencies"

msg_info "Enabling Docker service"
$STD systemctl enable --now docker
msg_ok "Docker service enabled"

msg_info "Creating data directories for EteSync"
mkdir -p /srv/etesync/data /srv/etesync/static
msg_ok "Created /srv/etesync/data and /srv/etesync/static"

msg_info "Pulling EteSync (Etebase) Docker image"
$STD docker pull victorrds/etesync:alpine
msg_ok "Pulled EteSync image"

msg_info "Creating EteSync container"
$STD docker create \
  --name etesync \
  --restart unless-stopped \
  -e SUPER_USER=admin \
  -e SERVER=http \
  -p 0.0.0.0:3735:3735 \
  -v /srv/etesync/data:/data \
  -v /srv/etesync/static:/srv/etebase/static \
  victorrds/etesync:alpine
msg_ok "Created EteSync container"

msg_info "Creating systemd service for EteSync"
cat <<'EOF' >/etc/systemd/system/etesync.service
[Unit]
Description=EteSync (Etebase) Server Docker Container
After=network-online.target docker.service
Wants=network-online.target

[Service]
Restart=always
RestartSec=5s
ExecStart=/usr/bin/docker start -a etesync
ExecStop=/usr/bin/docker stop -t 10 etesync

[Install]
WantedBy=multi-user.target
EOF

$STD systemctl daemon-reload
$STD systemctl enable --now etesync
msg_ok "EteSync service enabled and started"

motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
$STD apt-get -y clean
msg_ok "Cleaned"
