#!/usr/bin/env bash
set -euo pipefail

# Talos VM provisioning for Proxmox VE (qm)
# - Creates a VM
# - Generates (optional) Image Factory schematic (qemu-guest-agent)
# - Downloads Talos metal qcow2 disk image from factory.talos.dev
# - Imports disk and boots the VM
#
# Usage:
#   sudo ./talos-vm.sh
#
# Optional env vars:
#   VMID=110
#   VM_NAME=talos-cp-01
#   CORES=4
#   MEMORY=8192
#   DISK_STORAGE=local-lvm
#   BRIDGE=vmbr0
#   VLAN=0
#   MTU=0
#   DISK_SIZE_GB=32
#   TALOS_VERSION=v1.12.0   # default: latest from GitHub API
#   ARCH=amd64              # amd64/arm64 (seu Proxmox precisa suportar)
#   ENABLE_QGA=1            # 1 = adiciona siderolabs/qemu-guest-agent no schematic
#   SCHEMATIC_ID=...        # se setar, NÃO cria schematic; usa esse direto

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 1; }; }

need qm
need pvesh
need curl
need python3
need awk
need sed

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: rode como root (sudo)." >&2
  exit 1
fi

prompt_default() {
  local var="$1" default="$2" msg="$3"
  local current="${!var:-}"
  if [[ -n "$current" ]]; then
    return 0
  fi
  read -r -p "$msg [$default]: " val || true
  val="${val:-$default}"
  printf -v "$var" '%s' "$val"
}

get_next_vmid() {
  pvesh get /cluster/nextid 2>/dev/null || true
}

get_latest_talos_tag() {
  # Returns tag like "v1.12.0"
  curl -fsSL https://api.github.com/repos/siderolabs/talos/releases/latest \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["tag_name"])'
}

factory_create_schematic() {
  local yaml_file="$1"
  curl -fsSL -X POST --data-binary @"$yaml_file" https://factory.talos.dev/schematics \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])'
}

# -------- Defaults / prompts --------
: "${VMID:=}"
: "${VM_NAME:=}"
: "${CORES:=2}"
: "${MEMORY:=2048}"
: "${DISK_STORAGE:=}"
: "${BRIDGE:=vmbr0}"
: "${VLAN:=0}"
: "${MTU:=0}"
: "${DISK_SIZE_GB:=20}"
: "${TALOS_VERSION:=}"
: "${ARCH:=amd64}"
: "${ENABLE_QGA:=1}"
: "${SCHEMATIC_ID:=}"

if [[ -z "$VMID" ]]; then
  VMID="$(get_next_vmid)"
fi
prompt_default VMID "$VMID" "VMID"
prompt_default VM_NAME "talos-${VMID}" "Nome da VM"
prompt_default CORES "$CORES" "vCPUs"
prompt_default MEMORY "$MEMORY" "RAM (MB)"
prompt_default BRIDGE "$BRIDGE" "Bridge (ex: vmbr0)"
prompt_default VLAN "$VLAN" "VLAN tag (0 = sem VLAN)"
prompt_default MTU "$MTU" "MTU (0 = default)"
prompt_default DISK_SIZE_GB "$DISK_SIZE_GB" "Tamanho do disco (GB) (resize após import)"
prompt_default ARCH "$ARCH" "Arch (amd64/arm64)"

if [[ -z "$DISK_STORAGE" ]]; then
  # escolhe um storage que aceite "images"; preferindo local-lvm se existir
  if pvesm status 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "local-lvm"; then
    DISK_STORAGE="local-lvm"
  else
    # pega o primeiro storage listado (fallback)
    DISK_STORAGE="$(pvesm status | awk 'NR==2{print $1}')"
  fi
fi
prompt_default DISK_STORAGE "$DISK_STORAGE" "Storage para o disco (ex: local-lvm)"

if [[ -z "$TALOS_VERSION" ]]; then
  echo "Buscando última versão do Talos via GitHub API..."
  TALOS_VERSION="$(get_latest_talos_tag || true)"
fi
prompt_default TALOS_VERSION "${TALOS_VERSION:-v1.12.0}" "Talos version (tag, ex: v1.12.0)"

if qm status "$VMID" &>/dev/null; then
  echo "ERROR: já existe VM com VMID=$VMID" >&2
  exit 1
fi

# -------- Schematic / Image URL --------
TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

if [[ -z "$SCHEMATIC_ID" ]]; then
  echo "Gerando schematic no factory.talos.dev (ENABLE_QGA=$ENABLE_QGA)..."
  SCHEMATIC_YAML="$TMPDIR/schematic.yaml"
  if [[ "$ENABLE_QGA" == "1" ]]; then
    cat >"$SCHEMATIC_YAML" <<'YAML'
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/qemu-guest-agent
YAML
  else
    cat >"$SCHEMATIC_YAML" <<'YAML'
customization: {}
YAML
  fi
  SCHEMATIC_ID="$(factory_create_schematic "$SCHEMATIC_YAML")"
fi

IMG_URL="https://factory.talos.dev/image/${SCHEMATIC_ID}/${TALOS_VERSION}/metal-${ARCH}.qcow2"
IMG_FILE="$TMPDIR/talos-${TALOS_VERSION}-metal-${ARCH}.qcow2"

echo "Baixando Talos image:"
echo "  $IMG_URL"
curl -fL "$IMG_URL" -o "$IMG_FILE"

# -------- Create VM --------
NET_OPTS="virtio,bridge=${BRIDGE}"
if [[ "${VLAN}" != "0" && -n "${VLAN}" ]]; then
  NET_OPTS+=",tag=${VLAN}"
fi
if [[ "${MTU}" != "0" && -n "${MTU}" ]]; then
  NET_OPTS+=",mtu=${MTU}"
fi

echo "Criando VM $VMID ($VM_NAME)..."
qm create "$VMID" \
  --name "$VM_NAME" \
  --ostype l26 \
  --machine q35 \
  --bios ovmf \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --cpu host \
  --net0 "$NET_OPTS" \
  --scsihw virtio-scsi-single \
  --serial0 socket \
  --vga serial0 \
  --onboot 1

# EFI disk (necessário para OVMF/UEFI)
qm set "$VMID" --efidisk0 "${DISK_STORAGE}:0,format=raw,pre-enrolled-keys=0"

echo "Importando disco qcow2 para o storage ${DISK_STORAGE}..."
IMPORT_OUT="$(qm importdisk "$VMID" "$IMG_FILE" "$DISK_STORAGE" --format raw 2>&1 || true)"
echo "$IMPORT_OUT"

# Descobre o volid importado:
VOLID="$(echo "$IMPORT_OUT" | sed -n "s/.*Successfully imported disk as '\(.*\)'.*/\1/p" | tail -n1)"

# fallback: pega unused0 do config
if [[ -z "$VOLID" ]]; then
  VOLID="$(qm config "$VMID" | awk -F': ' '/^unused0:/{print $2}' | head -n1)"
fi

if [[ -z "$VOLID" ]]; then
  echo "ERROR: não consegui determinar o VOLID importado (unused0)." >&2
  echo "Dica: veja 'qm config $VMID' e ajuste manualmente scsi0." >&2
  exit 1
fi

echo "Anexando disco em scsi0: $VOLID"
qm set "$VMID" --scsi0 "${VOLID},discard=on,ssd=1,iothread=1"
# remove o unused0 se sobrou
qm set "$VMID" --delete unused0 >/dev/null 2>&1 || true

# Resize do disco (opcional)
if [[ -n "${DISK_SIZE_GB}" && "${DISK_SIZE_GB}" -gt 0 ]]; then
  echo "Redimensionando disco para ${DISK_SIZE_GB}G (qm resize)..."
  qm resize "$VMID" scsi0 "${DISK_SIZE_GB}G" || true
fi

# Qemu guest agent (se você colocou extensão)
if [[ "$ENABLE_QGA" == "1" ]]; then
  qm set "$VMID" --agent enabled=1,fstrim_cloned_disks=1 || true
fi

qm set "$VMID" --boot order=scsi0

echo "Iniciando VM..."
qm start "$VMID"

cat <<EOF

OK ✅ VM Talos criada e iniciada.

VMID:        $VMID
Nome:        $VM_NAME
Talos:       $TALOS_VERSION
Schematic:   $SCHEMATIC_ID
Imagem:      $IMG_URL

Próximos passos (no seu workstation com talosctl):
  1) Gere configs:
       talosctl gen config <CLUSTERNAME> <VIP_OU_ENDPOINT>
  2) Aponte talosctl para o nó (IP que aparecerá no console) e aplique:
       talosctl apply-config --insecure -n <NODE_IP> -f controlplane.yaml
  3) Bootstrap:
       talosctl bootstrap -n <NODE_IP>

Para ver o console da VM no Proxmox:
  qm terminal $VMID

EOF
