#!/usr/bin/env bash
# create-vm.sh — Generate OpenShift VirtualMachine manifests for Windows guests.
#
# Usage:
#   ./scripts/create-vm.sh --name win11-dev-01 [options]
#
# All credentials, cluster values, and registry paths are passed via flags
# or environment variables. No hardcoded secrets.

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
VM_NAME=""
NAMESPACE="virt-windows"
INSTANCETYPE="u1.large"
PREFERENCE=""
TEMPLATE="windows11"
BOOT_SIZE="30Gi"
DATA_SIZE="100Gi"
STORAGE_CLASS="nfs-csi"
NETWORK="default/vlan-60"
MAC=""
RUN_STRATEGY="RerunOnFailure"
OUTPUT=""
DRY_RUN=false
MACHINE_TYPE="pc-q35-rhel9.8.0"
VIRTIO_IMAGE="registry.redhat.io/container-native-virtualization/virtio-win-rhel9@sha256:7e06e1f52a434d4602657c920144504fbaed955d0998535bdf345716355ce83a"
DS_NAME=""
DS_NAMESPACE="openshift-virtualization-os-images"

# ── Template definitions ─────────────────────────────────────────────────────
resolve_template() {
  case "${TEMPLATE}" in
    windows11)
      DS_NAME="windows-11-25h2-amd64"
      PREFERENCE="windows.11.virtio"
      ;;
    windows2025)
      DS_NAME="windows-2025-virtio-amd64"
      PREFERENCE="windows.2k25.virtio"
      ;;
    *)
      echo "ERROR: Unknown template '${TEMPLATE}'. Supported: windows11, windows2025" >&2
      exit 1
      ;;
  esac
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<'USAGE'
Generate OpenShift VirtualMachine YAML for Windows guests.

Required:
  --name <name>           VM name (e.g. win11-dev-01)

Options:
  --template <tpl>        OS template: windows11, windows2025  (default: windows11)
  --namespace <ns>        Target namespace                     (default: virt-windows)
  --instancetype <it>     KubeVirt instance type               (default: u1.large)
  --data-size <size>      Data disk size                       (default: 100Gi)
  --storage-class <sc>    StorageClass name                    (default: nfs-csi)
  --network <net>         NetworkAttachmentDef ns/name         (default: default/vlan-60)
  --mac <mac>             Static MAC address                   (default: auto)
  --run-strategy <strat>  Run strategy                         (default: RerunOnFailure)
  --output <file>         Output file                          (default: <name>.yaml)
  --dry-run               Print to stdout instead of file
  --help                  Show this help

Examples:
  ./create-vm.sh --name win11-dev-01
  ./create-vm.sh --name win11-test --data-size 200Gi --namespace virt-test
  ./create-vm.sh --name win2025-01 --template windows2025 --dry-run
USAGE
  exit 0
}

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)          VM_NAME="$2";       shift 2 ;;
    --namespace)     NAMESPACE="$2";     shift 2 ;;
    --instancetype)  INSTANCETYPE="$2";  shift 2 ;;
    --template)      TEMPLATE="$2";      shift 2 ;;
    --data-size)     DATA_SIZE="$2";     shift 2 ;;
    --storage-class) STORAGE_CLASS="$2"; shift 2 ;;
    --network)       NETWORK="$2";       shift 2 ;;
    --mac)           MAC="$2";           shift 2 ;;
    --run-strategy)  RUN_STRATEGY="$2";  shift 2 ;;
    --output)        OUTPUT="$2";        shift 2 ;;
    --dry-run)       DRY_RUN=true;       shift   ;;
    --help)          usage ;;
    *)
      echo "ERROR: Unknown flag '$1'" >&2
      usage
      ;;
  esac
done

# Resolve template (after parsing so --template can override)
resolve_template

# ── Validation ────────────────────────────────────────────────────────────────
if [[ -z "${VM_NAME}" ]]; then
  echo "ERROR: --name is required" >&2
  usage
fi

# ── Generate UUIDs & MAC ─────────────────────────────────────────────────────
generate_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    python3 -c "import uuid; print(uuid.uuid4())"
  fi
}

VM_UUID=$(generate_uuid)
VM_SERIAL=$(generate_uuid)

if [[ -z "${MAC}" ]]; then
  MAC="02:f2:1a:$(python3 -c "import random; print('{:02x}:{:02x}:{:02x}'.format(random.randint(0,255), random.randint(0,255), random.randint(0,255)))")"
fi

# ── Parse network ─────────────────────────────────────────────────────────────
NET_NAMESPACE="${NETWORK%%/*}"
NET_NAME="${NETWORK##*/}"

# ── Output target ─────────────────────────────────────────────────────────────
if [[ -z "${OUTPUT}" ]]; then
  OUTPUT="${VM_NAME}.yaml"
fi

# ── Generate YAML ─────────────────────────────────────────────────────────────
generate_yaml() {
  cat <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${VM_NAME}
    app.kubernetes.io/component: windows-vm
    app.kubernetes.io/template: ${TEMPLATE}
spec:
  instancetype:
    name: ${INSTANCETYPE}
  preference:
    kind: VirtualMachineClusterPreference
    name: ${PREFERENCE}
  runStrategy: ${RUN_STRATEGY}

  dataVolumeTemplates:
    # Boot volume — cloned from OS DataSource
    - metadata:
        name: ${VM_NAME}-boot
      spec:
        sourceRef:
          kind: DataSource
          name: ${DS_NAME}
          namespace: ${DS_NAMESPACE}
        storage:
          resources:
            requests:
              storage: ${BOOT_SIZE}
          storageClassName: ${STORAGE_CLASS}

    # Data disk — blank, for guest OS installation
    - metadata:
        name: ${VM_NAME}-data
      spec:
        source:
          blank: {}
        storage:
          resources:
            requests:
              storage: ${DATA_SIZE}
          storageClassName: ${STORAGE_CLASS}

  template:
    metadata:
      annotations:
        kubevirt.io/pci-topology-version: v3
      labels:
        network.kubevirt.io/headlessService: headless
    spec:
      architecture: amd64
      subdomain: headless

      domain:
        devices:
          autoattachPodInterface: false
          disks:
            - bootOrder: 1
              name: rootdisk
            - bootOrder: 2
              cdrom:
                bus: sata
              name: cdrom-iso
            - cdrom:
                bus: sata
              name: windows-drivers-disk
          interfaces:
            - bridge: {}
              macAddress: ${MAC}
              model: virtio
              name: default
              state: up

        firmware:
          uuid: ${VM_UUID}
          serial: ${VM_SERIAL}

        machine:
          type: ${MACHINE_TYPE}

      networks:
        - multus:
            networkName: ${NET_NAMESPACE}/${NET_NAME}
          name: default

      volumes:
        - dataVolume:
            name: ${VM_NAME}-boot
          name: cdrom-iso
        - dataVolume:
            name: ${VM_NAME}-data
          name: rootdisk
        - containerDisk:
            image: ${VIRTIO_IMAGE}
          name: windows-drivers-disk
EOF
}

if "${DRY_RUN}"; then
  generate_yaml
else
  generate_yaml > "${OUTPUT}"
  echo "Generated ${OUTPUT}"
fi
