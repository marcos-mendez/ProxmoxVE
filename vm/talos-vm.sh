#!/usr/bin/env bash
set -euo pipefail

# Talos OS VM - Proxmox VE Helper-Style Script
# Creates a Talos VM by downloading a qcow2 from Talos Image Factory, importing it, and configuring the VM.

# ---------- UI helpers ----------
RD="\033[01;31m"; GN="\033[01;32m"; YW="\033[01;33m"; BL="\033[01;34m"; CL="\033[0m"
BOLD="\033[1m"

info()  { echo -e "${YW}⏳${CL} $*"; }
ok()    { echo -e "${GN}✅${CL} $*"; }
fail()  { echo -e "${RD}❌${CL} $*"; }
die()   { fail "$*"; exit 1; }

header() {
  clear
  echo -e "${BOLD}${BL}Proxmox VE - Talos OS VM Builder${CL}"
  echo -e "${BL}--------------------------------${CL}\n"
}

exit_script() {
  header
  echo -e "${RD}User exited script.${CL}\n"
  exit 0
}

check_root() {
  if [[ "$(id -u)" -ne 0 || "$(ps -o comm= -p "$PPID" 2>/dev/null || true)" == "sudo" ]]; then
    header
    die "Please run this script as root (no sudo wrapper)."
  fi
}

pve_check() {
  command -v pveversion >/dev/null 2>&1 || die "This does not look like a Proxmox node (pveversion not found)."
  local PVE_VER
  PVE_VER="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
  if [[ "$PVE_VER" =~ ^8\.([0-9]+) ]]; then
    local MINOR="${BASH_REMATCH[1]}"
    ((MINOR >= 0 && MINOR <= 9)) || die "Unsupported PVE $PVE_VER (supported: 8.0–8.9)."
    return
  fi
  if [[ "$PVE_VER" =~ ^9\.([0-9]+) ]]; then
    local MINOR="${BASH_REMATCH[1]}"
    ((MINOR >= 0 && MINOR <= 1)) || die "Unsupported PVE $PVE_VER (supported: 9.0–9.1)."
    return
  fi
  die "Unsupported Proxmox VE version: $PVE_VER"
}

arch_check() {
  [[ "$(dpkg --print-architecture)" == "amd64" ]] || die "This script is amd64-only (not PiMox/ARM)."
}

ssh_check() {
  if [[ -n "${SSH_CLIENT:+x}" ]]; then
    whiptail --backtitle "Proxmox VE Helper Scripts" --defaultno --title "SSH DETECTED" \
      --yesno "Sugestão: rodar no shell do Proxmox (SSH pode atrapalhar input de whiptail).\n\nDeseja continuar via SSH?" 10 68 \
      || exit_script
  fi
}

get_nextid() {
  if command -v pvesh >/dev/null 2>&1; then
    pvesh get /cluster/nextid 2>/dev/null || true
  fi
}

gen_mac() {
  # Use a fixed OUI-like prefix (locally administered) + random tail
  printf "BC:24:11:%02X:%02X:%02X" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

storage_select() {
  local STORAGES=()
  while read -r name type status _; do
    [[ "$status" == "active" ]] || continue
    STORAGES+=("$name" "$type")
  done < <(pvesm status -content images 2>/dev/null | awk 'NR>1 {print $1,$2,$3,$4}')

  ((${#STORAGES[@]} > 1)) || die "No active storage with 'images' content found."

  local menu=()
  local i=0
  while (( i < ${#STORAGES[@]} )); do
    menu+=("${STORAGES[i]}" "Type: ${STORAGES[i+1]}")
    i=$((i+2))
  done

  local chosen
  chosen="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "STORAGE" \
    --menu "Select storage for VM disks" 15 72 7 \
    "${menu[@]}" 3>&1 1>&2 2>&3)" || exit_script

  echo "$chosen"
}

storage_type_of() {
  pvesm status -storage "$1" 2>/dev/null | awk 'NR==2 {print $2}'
}

# ---------- Talos image factory helpers ----------
github_latest_talos() {
  # Returns tag_name like v1.9.?. If API fails, return empty.
  curl -fsSL https://api.github.com/repos/siderolabs/talos/releases/latest 2>/dev/null \
    | sed -nE 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' | head -n1 || true
}

factory_schematic_id() {
  local schematic_file="$1"
  curl -fsSL -X POST \
    -H "Content-Type: application/yaml" \
    --data-binary @"$schematic_file" \
    https://factory.talos.dev/schematics \
    | python3 -c 'import sys, json; print(json.load(sys.stdin)["id"])'
}

# ---------- Defaults / advanced ----------
default_settings() {
  VMID="$(get_nextid)"
  [[ -n "${VMID}" ]] || VMID="100"
  MACH="i440fx"
  DISK_SIZE="20G"
  DISK_CACHE="none"
  HN="talos"
  CPU_TYPE="kvm64"
  CORE_COUNT="2"
  RAM_SIZE="2048"
  BRG="vmbr0"
  MAC="$(gen_mac)"
  VLAN=""
  MTU=""
  START_VM="yes"
  ENABLE_QGA="yes"
  TALOS_VERSION="$(github_latest_talos)"
  [[ -n "$TALOS_VERSION" ]] || TALOS_VERSION="v1.9.0"
  METHOD="default"

  header
  echo -e "${BOLD}Settings:${CL}"
  echo -e "  VMID:              ${VMID}"
  echo -e "  Machine:           ${MACH}"
  echo -e "  Disk:              ${DISK_SIZE} (cache=${DISK_CACHE})"
  echo -e "  Hostname:          ${HN}"
  echo -e "  CPU:               ${CPU_TYPE}"
  echo -e "  Cores:             ${CORE_COUNT}"
  echo -e "  RAM:               ${RAM_SIZE} MB"
  echo -e "  Bridge:            ${BRG}"
  echo -e "  MAC:               ${MAC}"
  echo -e "  VLAN:              ${VLAN:-Default}"
  echo -e "  MTU:               ${MTU:-Default}"
  echo -e "  Talos version:     ${TALOS_VERSION}"
  echo -e "  QEMU Guest Agent:  ${ENABLE_QGA}"
  echo -e "  Start VM:          ${START_VM}\n"
}

advanced_settings() {
  METHOD="advanced"
  [[ -n "${VMID:-}" ]] || VMID="$(get_nextid)"
  [[ -n "${VMID}" ]] || VMID="100"

  while true; do
    VMID="$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Virtual Machine ID" 8 58 "$VMID" \
      --title "VIRTUAL MACHINE ID" --cancel-button Exit-Script 3>&1 1>&2 2>&3)" || exit_script
    [[ -n "$VMID" ]] || VMID="$(get_nextid)"
    if qm status "$VMID" &>/dev/null || pct status "$VMID" &>/dev/null; then
      whiptail --backtitle "Proxmox VE Helper Scripts" --title "ID IN USE" \
        --msgbox "ID $VMID is already in use." 8 48
      continue
    fi
    break
  done

  MACH="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "MACHINE TYPE" \
    --radiolist "Choose machine type" 10 58 2 \
    "i440fx" "Machine i440fx" ON \
    "q35"    "Machine q35"    OFF \
    3>&1 1>&2 2>&3)" || exit_script

  DISK_SIZE="$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Disk Size in GiB (e.g. 20, 50)" 8 58 "${DISK_SIZE%G}" \
    --title "DISK SIZE" --cancel-button Exit-Script 3>&1 1>&2 2>&3)" || exit_script
  DISK_SIZE="$(echo "$DISK_SIZE" | tr -d ' ')"
  [[ "$DISK_SIZE" =~ ^[0-9]+$ ]] || die "Invalid disk size: $DISK_SIZE"
  DISK_SIZE="${DISK_SIZE}G"

  DISK_CACHE="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "DISK CACHE" \
    --radiolist "Choose disk cache" 12 70 5 \
    "none"        "None (recommended)" ON \
    "writethrough" "Write Through"     OFF \
    "writeback"    "Write Back"        OFF \
    "directsync"   "Direct Sync"       OFF \
    "unsafe"       "Unsafe"            OFF \
    3>&1 1>&2 2>&3)" || exit_script

  HN="$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Hostname" 8 58 "${HN:-talos}" \
    --title "HOSTNAME" --cancel-button Exit-Script 3>&1 1>&2 2>&3)" || exit_script
  [[ -n "$HN" ]] || HN="talos"

  CPU_TYPE="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "CPU MODEL" \
    --radiolist "Choose CPU model" 10 58 2 \
    "kvm64" "KVM64 (portable)" ON \
    "host"  "Host (best perf)" OFF \
    3>&1 1>&2 2>&3)" || exit_script

  CORE_COUNT="$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "CPU Cores" 8 58 "${CORE_COUNT:-2}" \
    --title "CPU CORES" --cancel-button Exit-Script 3>&1 1>&2 2>&3)" || exit_script
  [[ "$CORE_COUNT" =~ ^[0-9]+$ ]] || die "Invalid cores: $CORE_COUNT"

  RAM_SIZE="$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "RAM (MB)" 8 58 "${RAM_SIZE:-2048}" \
    --title "RAM" --cancel-button Exit-Script 3>&1 1>&2 2>&3)" || exit_script
  [[ "$RAM_SIZE" =~ ^[0-9]+$ ]] || die "Invalid RAM: $RAM_SIZE"

  BRG="$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Bridge (e.g., vmbr0)" 8 58 "${BRG:-vmbr0}" \
    --title "BRIDGE" --cancel-button Exit-Script 3>&1 1>&2 2>&3)" || exit_script
  [[ -n "$BRG" ]] || BRG="vmbr0"

  MAC="$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "MAC Address" 8 58 "${MAC:-$(gen_mac)}" \
    --title "MAC" --cancel-button Exit-Script 3>&1 1>&2 2>&3)" || exit_script

  VLAN="$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "VLAN (blank = default)" 8 58 "${VLAN:-}" \
    --title "VLAN" --cancel-button Exit-Script 3>&1 1>&2 2>&3)" || exit_script
  MTU="$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "MTU (blank = default)" 8 58 "${MTU:-}" \
    --title "MTU" --cancel-button Exit-Script 3>&1 1>&2 2>&3)" || exit_script

  ENABLE_QGA="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "QEMU GUEST AGENT" \
    --radiolist "Include Talos system extension: siderolabs/qemu-guest-agent ?" 10 72 2 \
    "yes" "Yes (recommended for Proxmox)" ON \
    "no"  "No"                          OFF \
    3>&1 1>&2 2>&3)" || exit_script

  local latest
  latest="$(github_latest_talos)"
  [[ -n "$latest" ]] || latest="v1.9.0"
  TALOS_VERSION="$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Talos version tag (e.g., v1.9.5)" 8 58 "${TALOS_VERSION:-$latest}" \
    --title "TALOS VERSION" --cancel-button Exit-Script 3>&1 1>&2 2>&3)" || exit_script
  [[ -n "$TALOS_VERSION" ]] || TALOS_VERSION="$latest"

  START_VM="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "START VM" \
    --radiolist "Start VM when completed?" 10 58 2 \
    "yes" "Yes" ON \
    "no"  "No"  OFF \
    3>&1 1>&2 2>&3)" || exit_script
}

# ---------- Main ----------
main() {
  check_root
  pve_check
  arch_check
  ssh_check

  header
  local choice
  choice="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Talos OS VM" \
    --menu "Choose setup type" 10 60 2 \
    "default"  "Use default settings" \
    "advanced" "Customize settings" \
    3>&1 1>&2 2>&3)" || exit_script

  case "$choice" in
    default)  default_settings ;;
    advanced) advanced_settings ;;
    *) exit_script ;;
  esac

  local STORAGE
  STORAGE="$(storage_select)"
  local STYPE
  STYPE="$(storage_type_of "$STORAGE")"
  ok "Storage: $STORAGE (type: ${STYPE:-unknown})"

  if ! whiptail --backtitle "Proxmox VE Helper Scripts" --title "CONFIRM" \
    --yesno "Create Talos VM now?\n\nVMID: $VMID\nStorage: $STORAGE\nTalos: $TALOS_VERSION\nQGA: $ENABLE_QGA" 12 70; then
    exit_script
  fi

  # Compose net0 options
  local NET0="virtio,bridge=${BRG},macaddr=${MAC}"
  [[ -n "$VLAN" ]] && NET0="${NET0},tag=${VLAN}"
  [[ -n "$MTU"  ]] && NET0="${NET0},mtu=${MTU}"

  # Download Talos image via Factory
  info "Building Talos Image Factory schematic…"
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir" >/dev/null 2>&1 || true' EXIT

  local schematic="$tmpdir/schematic.yaml"
  if [[ "$ENABLE_QGA" == "yes" ]]; then
    cat >"$schematic" <<'YAML'
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/qemu-guest-agent
YAML
  else
    cat >"$schematic" <<'YAML'
customization: {}
YAML
  fi

  local SCHEMATIC_ID
  SCHEMATIC_ID="$(factory_schematic_id "$schematic")" || die "Failed to get schematic id from Image Factory."
  ok "Schematic ID: $SCHEMATIC_ID"

  local FILE="$tmpdir/talos-${TALOS_VERSION}-${SCHEMATIC_ID}.qcow2"
  local URL="https://factory.talos.dev/image/${SCHEMATIC_ID}/${TALOS_VERSION}/metal-amd64.qcow2"

  info "Downloading Talos image…"
  curl -fL --progress-bar -o "$FILE" "$URL" || die "Download failed: $URL"
  ok "Downloaded: $FILE"

  # Create VM
  info "Creating VM $VMID…"
  local BIOS="ovmf"
  local MACHINE_OPT=""
  [[ "$MACH" == "q35" ]] && MACHINE_OPT="--machine q35"

  # Enable agent in Proxmox only if we baked QGA into Talos
  local AGENT_OPT="0"
  [[ "$ENABLE_QGA" == "yes" ]] && AGENT_OPT="1"

  qm create "$VMID" \
    --name "$HN" \
    --memory "$RAM_SIZE" \
    --cores "$CORE_COUNT" \
    --cpu "$CPU_TYPE" \
    --net0 "$NET0" \
    --bios "$BIOS" \
    $MACHINE_OPT \
    --ostype l26 \
    --scsihw virtio-scsi-pci \
    --serial0 socket \
    --vga serial0 \
    --tablet 0 \
    --localtime 1 \
    --onboot 1 \
    --agent "$AGENT_OPT" >/dev/null

  # Create EFI disk (Proxmox allocates volume automatically)
  info "Adding EFI disk…"
  qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=0" >/dev/null

  # Import Talos disk
  info "Importing Talos disk into storage…"
  local import_fmt=()
  if [[ "${STYPE:-}" == "btrfs" ]]; then
    import_fmt=(--format raw)
  fi
  qm importdisk "$VMID" "$FILE" "$STORAGE" "${import_fmt[@]}" >/dev/null

  # Attach imported disk
  local UNUSED
  UNUSED="$(qm config "$VMID" | awk -F': ' '/^unused0:/{print $2}')"
  [[ -n "$UNUSED" ]] || die "Could not find imported disk (unused0) in qm config."

  local cache_opt=""
  [[ -n "$DISK_CACHE" ]] && cache_opt=",cache=${DISK_CACHE}"

  info "Attaching disk as scsi0…"
  qm set "$VMID" --scsi0 "${UNUSED},discard=on,ssd=1${cache_opt}" >/dev/null
  qm set "$VMID" --boot order=scsi0 >/dev/null

  info "Resizing disk to ${DISK_SIZE}…"
  qm resize "$VMID" scsi0 "$DISK_SIZE" >/dev/null

  # Description
  qm set "$VMID" --description "Talos OS VM (${TALOS_VERSION})
- Built via Talos Image Factory
- QEMU Guest Agent baked: ${ENABLE_QGA}
Next steps:
- Boot VM and apply Talos config with talosctl (apply-config/bootstrap)." >/dev/null

  ok "VM $VMID created."

  if [[ "$START_VM" == "yes" ]]; then
    info "Starting VM…"
    qm start "$VMID" >/dev/null
    ok "VM started."
  else
    ok "VM not started (per your choice)."
  fi

  echo
  echo -e "${BOLD}Next steps (Talos):${CL}"
  echo -e "  1) Open Proxmox console (serial) or run:  ${BOLD}qm terminal $VMID${CL}"
  echo -e "  2) Get the VM IP (via console or DHCP lease)."
  echo -e "  3) Apply config:  ${BOLD}talosctl apply-config --insecure --nodes <IP> --file controlplane.yaml${CL}"
  echo -e "  4) Bootstrap:     ${BOLD}talosctl bootstrap --nodes <IP>${CL}"
  echo
}

main "$@"
