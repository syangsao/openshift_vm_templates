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

## Manual Creation (Without the Script)

Follow these steps to create a Windows 11 VM by hand.

### Prerequisites

Verify the cluster has the required resources:

```bash
# DataSource must exist
oc get datasource windows-11-25h2-amd64 -n openshift-virtualization-os-images

# Instancetype and preference must exist
oc get virtualmachineclusterinstancetype u1.large
oc get virtualmachineclusterpreference windows.11.virtio

# NetworkAttachmentDef must exist
oc get network-attachment-definition vlan-60 -n default

# StorageClass must exist
oc get storageclass nfs-csi
```

### Step 1: Generate Unique Identifiers

Each VM requires unique UUIDs and optionally a static MAC address:

```bash
# Generate firmware UUID
VM_UUID=$(cat /proc/sys/kernel/random/uuid)

# Generate firmware serial
VM_SERIAL=$(cat /proc/sys/kernel/random/uuid)

# Generate MAC (locally-administered, OUI 02:F2:1A)
# Or use a specific MAC for DHCP reservation
VM_MAC="02:f2:1a:73:a8:65"

echo "UUID:  $VM_UUID"
echo "Serial: $VM_SERIAL"
echo "MAC:    $VM_MAC"
```

### Step 2: Create the VirtualMachine Manifest

Replace `win11-dev-01` with your desired VM name, and substitute the UUIDs/MAC from Step 1:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: win11-dev-01
  namespace: virt-windows
spec:
  instancetype:
    name: u1.large
  preference:
    kind: VirtualMachineClusterPreference
    name: windows.11.virtio
  runStrategy: RerunOnFailure

  dataVolumeTemplates:
    # Boot volume — cloned from the Windows 11 25H2 DataSource
    - metadata:
        name: win11-dev-01-boot
      spec:
        sourceRef:
          kind: DataSource
          name: windows-11-25h2-amd64
          namespace: openshift-virtualization-os-images
        storage:
          resources:
            requests:
              storage: 30Gi
          storageClassName: nfs-csi

    # Data disk — blank, for guest OS installation
    - metadata:
        name: win11-dev-01-data
      spec:
        source:
          blank: {}
        storage:
          resources:
            requests:
              storage: 100Gi
          storageClassName: nfs-csi

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
              macAddress: 02:f2:1a:73:a8:65
              model: virtio
              name: default
              state: up

        firmware:
          uuid: <VM_UUID>
          serial: <VM_SERIAL>

        machine:
          type: pc-q35-rhel9.8.0

      networks:
        - multus:
            networkName: default/vlan-60
          name: default

      volumes:
        - dataVolume:
            name: win11-dev-01-boot
          name: cdrom-iso
        - dataVolume:
            name: win11-dev-01-data
          name: rootdisk
        - containerDisk:
            image: registry.redhat.io/container-native-virtualization/virtio-win-rhel9@sha256:7e06e1f52a434d4602657c920144504fbaed955d0998535bdf345716355ce83a
          name: windows-drivers-disk
```

**Key fields to customize:**

| Field | Purpose | Example |
|---|---|---|
| `metadata.name` | VM name | `win11-dev-01` |
| `metadata.namespace` | Target namespace | `virt-windows` |
| `spec.dataVolumeTemplates[*].name` | Must match `<vm-name>-boot` and `<vm-name>-data` | `win11-dev-01-boot` |
| `spec.template.spec.domain.devices.disks[*].name` | DV names referenced as volumes | `rootdisk`, `cdrom-iso` |
| `spec.template.spec.domain.firmware.uuid` | Unique per VM | Output from Step 1 |
| `spec.template.spec.domain.firmware.serial` | Unique per VM | Output from Step 1 |
| `spec.template.spec.domain.devices.interfaces[0].macAddress` | Static MAC (optional) | `02:f2:1a:73:a8:65` |
| `spec.template.spec.networks[0].multus.networkName` | NetworkAttachmentDef ref | `default/vlan-60` |

### Step 3: Apply the Manifest

```bash
# Save the YAML above to win11-dev-01.yaml, then:
oc apply -f win11-dev-01.yaml -n virt-windows
```

### Step 4: Wait for DataVolumes to Provision

The boot volume is cloned from the DataSource. The data volume is created blank. Watch progress:

```bash
# Watch DataVolume status
oc get datavolume -n virt-windows -w

# Expected output:
# NAME                  PHASE       PROGRESS
# win11-dev-01-boot     Filling     25.3%
# win11-dev-01-data     Bound       N/A
```

Both must reach `Succeeded` before starting the VM. The boot volume clone typically takes 2–5 minutes depending on storage performance.

### Step 5: Start the VM

```bash
oc start vm/win11-dev-01 -n virt-windows
```

Verify it is running:

```bash
oc get vm/win11-dev-01 -n virt-windows
# STATUS should be Running

# Check the VMI details
oc get vmi/win11-dev-01 -n virt-windows -o yaml
```

### Step 6: Connect to the VM Console

```bash
# Use the noVNC console
oc virt-launcher-console win11-dev-01 -n virt-windows

# Or get the SPICE URL for virt-viewer
oc virt-launcher-spice-url win11-dev-01 -n virt-windows
```

### Step 7: Install Windows

1. The VM boots from the Windows 11 ISO (bootOrder 2, CD-ROM).
2. The blank data disk (bootOrder 1) is the installation target.
3. Windows Setup will detect the blank disk. Select it for installation.
4. If Windows does not detect the disk, load the virtio drivers from the second CD-ROM (`windows-drivers-disk`):
   - During disk selection, click **Load Driver**
   - Browse to the virtio drivers CD-ROM
   - Select the appropriate storage driver (usually `viostor` for SCSI)
5. Complete the Windows installation.
6. After reboot, install the remaining virtio drivers (network, balloon, QEMU guest agent) from the drivers CD-ROM.

### Step 8: Verify Post-Installation

```bash
# Check the VMI is healthy
oc get vmi/win11-dev-01 -n virt-windows

# Check interface IP (if guest agent is installed)
oc describe vmi/win11-dev-01 -n virt-windows | grep -A5 "Interfaces:"

# Take a snapshot for backup
oc create volumesnapshot win11-dev-01-snapshot \
  --source=pvc/win11-dev-01-data \
  -n virt-windows
```
