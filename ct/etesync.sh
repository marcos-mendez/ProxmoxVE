#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2025 Community-Scripts ORG
# Author: Marcos Mendez / POP.COOP
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://www.etesync.com/

APP="EteSync"
var_tags="${var_tags:-calendar}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-8}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  msg_info "Updating base system"
  $STD apt-get update
  $STD apt-get -y upgrade
  msg_ok "Base system updated"

  if command -v docker >/dev/null 2>&1; then
    msg_info "Updating EteSync Docker image"
    $STD docker pull victorrds/etesync:alpine || msg_warn "Failed to pull latest EteSync image"
    if systemctl is-active --quiet etesync; then
      systemctl restart etesync
    fi
    msg_ok "EteSync image updated (if pull succeeded)"
  else
    msg_warn "Docker not found, skipping EteSync image update"
  fi

  msg_info "Cleaning up"
  $STD apt-get -y autoremove
  $STD apt-get -y autoclean
  msg_ok "Cleanup complete"

  msg_ok "Updated successfully!"
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} LXC has been successfully created!${CL}"
echo -e "${INFO}${YW} Point your EteSync apps / DAV bridge to:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:3735${CL}"
echo -e "${INFO}${YW} Recomenda-se colocar atrás de um reverse proxy (Nginx/Traefik) com TLS.${CL}"
