# Cluster Reference

Cluster-specific values for the **luke** OpenShift cluster (OCP 4.21.15, ODF 4.21.5).

## OS Images

| DataSource | Namespace | Size | Status |
|---|---|---|---|
| `windows-11-25h2-amd64` | `openshift-virtualization-os-images` | 30Gi | Succeeded |
| `windows-2025-virtio-amd64` | `openshift-virtualization-os-images` | 30Gi | Succeeded |
| `centos-stream10-1639602990ee` | `openshift-virtualization-os-images` | — | Succeeded |
| `centos-stream9-960115acc0c8` | `openshift-virtualization-os-images` | — | Succeeded |
| `rhel10-c5b97492a6e3` | `openshift-virtualization-os-images` | — | Succeeded |
| `rhel9-7005186c23b8` | `openshift-virtualization-os-images` | — | Succeeded |
| `rhel8-c6a08edc555b` | `openshift-virtualization-os-images` | — | Succeeded |
| `fedora-1217dcc8c58d` | `openshift-virtualization-os-images` | — | Succeeded |

## Instance Types

| Name | vCPU | RAM | Class |
|---|---|---|---|
| `u1.large` | 2 | 8Gi | general.purpose |

## Preferences

| Name | OS | Key Features |
|---|---|---|
| `windows.11.virtio` | Windows 11 | Secure Boot, TPM, virtio, Hyper-V enlightenments |
| `windows.2k25.virtio` | Windows Server 2025 | Secure Boot, TPM, virtio, Hyper-V enlightenments |

## Storage

| StorageClass | Provisioner | Access Mode |
|---|---|---|
| `nfs-csi` | NFS CSI (ODF standalone MCG) | ReadWriteMany |

## Network

| NetworkAttachmentDef | Namespace | Type | Description |
|---|---|---|---|
| `vlan-60` | `default` | OVN localnet | VLAN 60 connection for VMs |

## Virtio Drivers

```
registry.redhat.io/container-native-virtualization/virtio-win-rhel9@sha256:7e06e1f52a434d4602657c920144504fbaed955d0998535bdf345716355ce83a
```

## Windows 11 VM Disk Layout

1. **Boot volume** — 30Gi, cloned from DataSource. Attached as CD-ROM (bootOrder 2). Contains the Windows 11 25H2 ISO.
2. **Data volume** — Configurable (default 100Gi), blank. Attached as disk (bootOrder 1). The guest OS installs here.
3. **Virtio drivers** — containerDisk. Provides network, storage, balloon drivers.

## DataSource Details

The `windows-11-25h2-amd64` DataSource:

- Backed by DataVolume with `upload: {}` source (manually uploaded ISO)
- Labels: `kubevirt.io/iso: "true"`, `instancetype.kubevirt.io/default-preference: windows.11.virtio`
- Access mode: `ReadWriteMany`
- StorageClass: `nfs-csi`

## Reference VMs

| VM | Namespace | Status | Data Disk |
|---|---|---|---|
| `windows11-virtio` | `virt-windows` | Stopped | 100Gi |
| `windows-2025-virtio` | `virt-windows` | Stopped | 30Gi |
