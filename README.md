# OpenShift VM Templates

VirtualMachine templates and provisioning scripts for OpenShift Virtualization.

## Quick Start

```bash
# Generate a Windows 11 VM manifest
./scripts/create-vm.sh \
  --name win11-dev-01 \
  --namespace virt-windows \
  --instancetype u1.large \
  --data-size 100Gi \
  --network default/vlan-60 \
  --mac 02:f2:1a:73:a8:65

# Apply it
oc apply -f win11-dev-01.yaml

# Start it
oc start vm/win11-dev-01 -n virt-windows
```

## Templates

| Template | OS | Boot Source | Min Disk |
|----------|-----|-------------|----------|
| `windows11` | Windows 11 25H2 | `windows-11-25h2-amd64` DataSource | 30Gi |

## Cluster Reference (luke)

| Resource | Namespace | Value |
|----------|-----------|-------|
| DataSource | `openshift-virtualization-os-images` | `windows-11-25h2-amd64` |
| Instancetype | cluster-scoped | `u1.large` (2 vCPU, 8Gi RAM) |
| Preference | cluster-scoped | `windows.11.virtio` |
| StorageClass | cluster-scoped | `nfs-csi` |
| NetworkAttachmentDef | `default` | `vlan-60` (OVN localnet) |
| Virtio drivers | containerDisk | `registry.redhat.io/container-native-virtualization/virtio-win-rhel9@sha256:7e06e1f52a434d4602657c920144504fbaed955d0998535bdf345716355ce83a` |

## Architecture

Each VM uses a two-disk pattern:

1. **Boot volume** — Cloned from the OS DataSource (30Gi). Attached as CD-ROM during install.
2. **Data volume** — Blank disk (configurable size). The guest OS is installed here.

The Virtio drivers containerDisk provides network, storage, and balloon drivers for Windows guests.

## Script Options

See `./scripts/create-vm.sh --help` for all options. Key parameters:

| Flag | Description | Default |
|------|-------------|---------|
| `--name` | VM name (required) | — |
| `--namespace` | Target namespace | `virt-windows` |
| `--instancetype` | KubeVirt instance type | `u1.large` |
| `--data-size` | Data disk size | `100Gi` |
| `--network` | NetworkAttachmentDef (namespace/name) | `default/vlan-60` |
| `--mac` | Static MAC address | auto-generated |
| `--run-strategy` | Run strategy | `RerunOnFailure` |
| `--output` | Output file | `{name}.yaml` |
| `--dry-run` | Print to stdout instead of file | — |
