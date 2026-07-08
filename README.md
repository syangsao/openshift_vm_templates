# OpenShift VM Templates

Windows VirtualMachine templates, provisioning scripts, and automation for OpenShift Virtualization.

## Contents

- [Prerequisites](#prerequisites)
  - [Download and Upload VirtIO Drivers](#download-and-upload-virtio-drivers) — RPM → ISO → cluster upload
  - [Download and Upload Windows Server 2025 ISO](#download-and-upload-windows-server-2025-iso) — VLSC → ISO → DataSource
- [WIM-to-Disk: Import Custom Windows Images](#wim-to-disk-import-custom-windows-images) — Convert a .wim to a bootable disk, upload, deploy
- [Manual Golden Image Workflow](#manual-golden-image-workflow) — Step-by-step: build, generalize, clone
- [unattend.xml Reference](#unattendxml-reference) — Automated Windows installation
- [Automation (still need to validate)](#automation-still-need-to-validate) — Script and Ansible playbook
- [Templates](#templates)
- [Troubleshooting](#troubleshooting)
- [Cluster Reference](CLUSTER_REFERENCE.md) — Cluster-specific values (luke)

---

## Prerequisites

### Cluster Resources

Verify the cluster has the required resources:

```bash
# DataSources (Windows ISOs)
oc get datasource windows-11-25h2-amd64 -n openshift-virtualization-os-images
oc get datasource windows-server-2025 -n openshift-virtualization-os-images

# Instance type and preference
oc get virtualmachineclusterinstancetype u1.large
oc get virtualmachineclusterpreference windows.11.virtio

# Network
oc get network-attachment-definition vlan-60 -n default

# Storage
oc get storageclass nfs-csi
```

### Architecture

Each VM uses a three-disk pattern:

1. **Boot volume** — Cloned from the OS DataSource (30Gi). Attached as CD-ROM during install.
2. **Data volume** — Blank disk (configurable size). The guest OS is installed here.
3. **Virtio drivers** — CD-ROM ISO. Provides network, storage, and balloon drivers.

**Namespace strategy:**

| Namespace | Purpose |
|---|---|
| `openshift-virtualization-os-images` | Shared ISOs, DataSources, golden images. Cluster-wide. |
| `virt-windows` (or any project) | VMs, DataVolumes, PVCs. Project-scoped. |

Upload all reusable images to `openshift-virtualization-os-images` so any project can reference them via DataSource without re-uploading.

---

### Download and Upload VirtIO Drivers

The OpenShift Virtualization containerDisk for VirtIO may be outdated. Download the latest ISO from Red Hat and upload it to the cluster.

```bash
# 1. Download the latest RPM from Red Hat
# Replace the URL with the latest version from:
# https://access.redhat.com/downloads/content/virtio-win
curl -L -o virtio-win.rpm \
  "https://access.cdn.redhat.com/content/origin/rpms/virtio-win/1.9.57/0.el10_2/fd431d51/virtio-win-1.9.57-0.el10_2.noarch.rpm"

# 2. Extract the RPM
rpm2cpio virtio-win.rpm | cpio -idmv

# 3. Locate the ISO (typically in usr/share/virtio-win/)
ls -lh usr/share/virtio-win/virtio-win-*.iso

# 4. Copy to a working directory
cp usr/share/virtio-win/virtio-win-1.9.57.iso virtio-win.iso
```

**Upload via Web Console:**

1. Navigate to **Virtualization** → **Virtual Machines** → Your-VM → **Configuration** → **Storage**
2. Click **Add** → **CD-ROM**
3. Name: `cd-rom-virtio-win-1-9-57`
4. Select **"Select or upload a new ISO file to the cluster"**
5. Check **"Upload a new ISO file to the cluster"**
6. Click **Upload** and select the extracted ISO
7. Wait for upload to complete
8. **Reboot the VM**

**Note:** This same ISO can be attached to other VMs without re-uploading.

**Upload via CLI:**

Upload ISOs to `openshift-virtualization-os-images` so they are available cluster-wide. Any project can reference them without re-uploading.

```bash
# Create a DataVolume for the ISO
oc apply -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: virtio-win-iso
  namespace: openshift-virtualization-os-images
  annotations:
    cdi.kubevirt.io/storage.bind.immediate.requested: "true"
spec:
  storage:
    resources:
      requests:
        storage: 1Gi
    accessModes:
      - ReadWriteMany
    storageClassName: nfs-csi
  source:
    upload: {}
EOF

# Upload the ISO
virtctl image-upload dv virtio-win-iso \
  --size=1G \
  --image-path=virtio-win.iso \
  --insecure \
  --force-bind \
  -n openshift-virtualization-os-images
```

**Inside the guest OS:** Open the ISO and run the driver installer:

```
D:\virtio-win-gt-x64.msi
```

This installs all VirtIO drivers (NetKVM, viostor, balloon, qxl, etc.) in one step.

---

### Download and Upload Windows Server 2025 ISO

Download the Windows Server 2025 ISO from the Microsoft Volume Licensing portal, upload it to the cluster, and create a DataSource.

**Download:**

1. Go to [Microsoft Volume Licensing Service Center](https://www.microsoft.com/licensing/servicecenter)
2. Navigate to **Products and Services** → **Windows Server 2025**
3. Download the **Windows Server 2025 Datacenter** ISO (English, x64)
4. Copy the ISO to your workstation

**Upload via CLI:**

```bash
# Create a DataVolume for the ISO
oc apply -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: windows-server-2025-iso
  namespace: openshift-virtualization-os-images
  annotations:
    cdi.kubevirt.io/storage.bind.immediate.requested: "true"
spec:
  storage:
    resources:
      requests:
        storage: 6Gi
    accessModes:
      - ReadWriteMany
    storageClassName: nfs-csi
  source:
    upload: {}
EOF

# Upload the ISO
virtctl image-upload dv windows-server-2025-iso \
  --size=6G \
  --image-path=Windows_Server_2025.iso \
  --insecure \
  --force-bind \
  -n openshift-virtualization-os-images

# Wait for upload to complete
oc get datavolume windows-server-2025-iso -n openshift-virtualization-os-images -w
# PHASE should be "Succeeded"
```

**Create a DataSource:**

```bash
oc apply -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: windows-server-2025
  namespace: openshift-virtualization-os-images
spec:
  source:
    pvc:
      namespace: openshift-virtualization-os-images
      name: windows-server-2025-iso
EOF
```

**Verify:**

```bash
oc get datasource windows-server-2025 -n openshift-virtualization-os-images
```

When creating the VM manifest, reference this DataSource in the boot volume:

```yaml
sourceRef:
  kind: DataSource
  name: windows-server-2025
  namespace: openshift-virtualization-os-images
```

Also update the VirtIO driver path during Windows Setup to `viostor\ws2025\amd64\` instead of `viostor\w11\amd64\`.

---

## WIM-to-Disk: Import Custom Windows Images

Skip the ISO install entirely. Convert a `.wim` file (from a Windows ISO or custom capture) into a bootable disk image, upload it to OpenShift, and deploy VMs directly.

**When to use:** You have a custom `.wim` (e.g., from `DISM`, `imagex`, or a vendor image) and want to deploy it without going through the interactive Windows Setup.

### Step 1: Prepare the WIM File

Extract the `.wim` from your Windows ISO or locate your custom image:

```bash
# Mount the ISO
mkdir -p /tmp/windows-iso
mount -o loop Windows11.iso /tmp/windows-iso

# Locate the WIM (usually in sources/install.wim or install.esd)
ls -lh /tmp/windows-iso/sources/install.wim

# List available images in the WIM
wiminfo /tmp/windows-iso/sources/install.wim

# Example output:
# Image Count: 4
# Image 1: Windows 11 Home
# Image 2: Windows 11 Home N
# Image 3: Windows 11 Pro
# Image 4: Windows 11 Pro N
```

Note the image index or name you want to deploy.

### Step 2: Create a Raw Disk Image

Create a blank raw disk with enough space for the WIM content:

```bash
# Create a 64Gi raw disk image
dd if=/dev/zero of=windows-disk.img bs=1M count=0 seek=65536

# Partition the disk (EFI + MSR + primary NTFS)
parted --script windows-disk.img mklabel gpt
parted --script windows-disk.img mkpart primary fat32 1MiB 1011MiB
parted --script windows-disk.img set 1 esp on
parted --script windows-disk.img mkpart primary ntfs 1011MiB 1275MiB
parted --script windows-disk.img mkpart primary ntfs 1275MiB 100%

# Loop-mount the partitions
LOOP=$(losetup --find --show --partscan windows-disk.img)
echo "Loop device: $LOOP"

# Format partitions
mkfs.vfat -F 32 ${LOOP}p1    # EFI
mkfs.ntfs -f ${LOOP}p2       # MSR (leave mostly empty)
mkfs.ntfs -f ${LOOP}p3       # Windows root

# Mount the NTFS partition
mkdir -p /mnt/windows
mount -t ntfs ${LOOP}p3 /mnt/windows
```

### Step 3: Apply the WIM to the Disk

```bash
# Apply the WIM image to the mounted NTFS partition
# Replace '3' with your desired image index
wimapply /tmp/windows-iso/sources/install.wim 3 /mnt/windows

# Unmount
umount /mnt/windows
rmdir /mnt/windows

# Detach loop device
losetup -d $LOOP
```

### Step 4: Convert to QCOW2 (Optional but Recommended)

QCOW2 provides thin provisioning and better performance with KubeVirt:

```bash
qemu-img convert -f raw -O qcow2 windows-disk.img windows-disk.qcow2

# Verify
qemu-img info windows-disk.qcow2
```

### Step 5: Upload to OpenShift as a DataVolume

Upload to `openshift-virtualization-os-images` so the image is available cluster-wide:

```bash
# Create the DataVolume manifest
cat > windows-wim-dv.yaml <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: windows-wim-image
  namespace: openshift-virtualization-os-images
  annotations:
    cdi.kubevirt.io/storage.bind.immediate.requested: "true"
spec:
  storage:
    resources:
      requests:
        storage: 64Gi
    accessModes:
      - ReadWriteOnce
    storageClassName: nfs-csi
  source:
    upload: {}
EOF

oc apply -f windows-wim-dv.yaml

# Upload the image
virtctl image-upload dv windows-wim-image \
  --size=64G \
  --image-path=windows-disk.qcow2 \
  --insecure \
  --force-bind \
  -n openshift-virtualization-os-images

# Wait for upload to complete
oc get datavolume windows-wim-image -n openshift-virtualization-os-images -w
# PHASE should be "Succeeded"
```

### Step 6: Create a DataSource

```bash
oc apply -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: windows-wim-custom-v1
  namespace: openshift-virtualization-os-images
spec:
  source:
    pvc:
      namespace: openshift-virtualization-os-images
      name: windows-wim-image
EOF
```

### Step 7: Deploy VMs from the WIM DataSource

Clone the template and update the data disk to source from the WIM DataSource instead of a blank volume:

```yaml
# In the dataVolumeTemplates section, change:
#   source:
#     blank: {}
# To:
sourceRef:
  kind: DataSource
  name: windows-wim-custom-v1
  namespace: openshift-virtualization-os-images

# Also change the disk name from rootdisk to match your DV:
- dataVolume:
    name: <vm-name>-data
  name: rootdisk
```

The VM boots directly from the WIM-deployed disk — no ISO install required.

---

## Manual Golden Image Workflow

Build a fully configured Windows VM, generalize it with Sysprep, then clone it to deploy identical VMs in seconds.

**Why golden images:** Deploying multiple identical Windows VMs without rebuilding from ISO each time. Per-VM provisioning drops from ~15 minutes to ~30 seconds.

---

### Step 1: Generate Unique Identifiers

Each VM requires unique firmware UUIDs and optionally a static MAC address:

```bash
# Firmware UUID
VM_UUID=$(cat /proc/sys/kernel/random/uuid)

# Firmware serial
VM_SERIAL=$(cat /proc/sys/kernel/random/uuid)

# MAC address (locally-administered, OUI 02:F2:1A)
VM_MAC="02:f2:1a:73:a8:65"

echo "UUID:   $VM_UUID"
echo "Serial: $VM_SERIAL"
echo "MAC:    $VM_MAC"
```

---

### Step 2: Create the VirtualMachine Manifest

Create the YAML by hand or use `templates/windows11-vm.yaml` as a reference. Replace `<vm-name>`, UUIDs, and MAC with your values:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: <vm-name>
  namespace: virt-windows
spec:
  instancetype:
    name: u1.large
  preference:
    kind: VirtualMachineClusterPreference
    name: windows.11.virtio
  runStrategy: RerunOnFailure

  dataVolumeTemplates:
    # Boot volume — cloned from OS DataSource
    - metadata:
        name: <vm-name>-boot
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
        name: <vm-name>-data
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
              macAddress: <vm-mac>
              model: virtio
              name: default
              state: up

        firmware:
          uuid: <vm-uuid>
          serial: <vm-serial>

        machine:
          type: pc-q35-rhel9.8.0

      networks:
        - multus:
            networkName: default/vlan-60
          name: default

      volumes:
        - dataVolume:
            name: <vm-name>-boot
          name: cdrom-iso
        - dataVolume:
            name: <vm-name>-data
          name: rootdisk
        - containerDisk:
            image: registry.redhat.io/container-native-virtualization/virtio-win-rhel9@sha256:7e06e1f52a434d4602657c920144504fbaed955d0998535bdf345716355ce83a
          name: windows-drivers-disk
```

**Key fields to customize:**

| Field | Purpose | Example |
|---|---|---|
| `metadata.name` | VM name | `win11-golden` |
| `spec.dataVolumeTemplates[*].name` | Must match `<vm-name>-boot` and `<vm-name>-data` | `win11-golden-boot` |
| `firmware.uuid` / `firmware.serial` | Unique per VM | Output from Step 1 |
| `interfaces[0].macAddress` | Static MAC (optional) | `02:f2:1a:73:a8:65` |
| `networks[0].multus.networkName` | NetworkAttachmentDef ref | `default/vlan-60` |

---

### Step 3: Apply the Manifest

```bash
oc apply -f <vm-name>.yaml -n virt-windows
```

---

### Step 4: Wait for DataVolumes to Provision

The boot volume is cloned from the DataSource. The data volume is created blank. Both must reach `Succeeded` before starting the VM:

```bash
oc get datavolume -n virt-windows -w

# Expected output:
# NAME                PHASE       PROGRESS
# win11-golden-boot   Filling     25.3%
# win11-golden-data   Bound       N/A
```

The boot volume clone typically takes 2-5 minutes depending on storage performance.

---

### Step 5: Start the VM

```bash
oc start vm/<vm-name> -n virt-windows

# Verify
oc get vm/<vm-name> -n virt-windows
# STATUS should be Running
```

---

### Step 6: Connect to the VM Console

```bash
# noVNC console
oc virt-launcher-console <vm-name> -n virt-windows

# SPICE URL for virt-viewer
oc virt-launcher-spice-url <vm-name> -n virt-windows
```

---

### Step 7: Install Windows

1. VM boots from Windows ISO (bootOrder 2, CD-ROM)
2. Blank data disk (bootOrder 1) is the installation target
3. If Windows does not detect the disk, load the virtio storage driver from `windows-drivers-disk`:
   - Click **Load Driver** → browse to `viostor\w11\amd64\` (Windows 11) or `viostor\ws2025\amd64\` (Server 2025) → select driver
4. Complete the Windows installation
5. After reboot, install remaining virtio drivers from the drivers CD-ROM:
   - Network driver (`NetKVM`)
   - Balloon driver
   - **QEMU Guest Agent** (`qemu-ga-x86_64.msi`) — required for IP detection

---

### Step 8: Configure the Base VM

Inside the Windows VM, install applications, configure settings, and apply patches as needed. This is your golden image baseline.

---

### Step 9: Create unattend.xml (Optional)

If you want clones to automatically configure hostname and network on first boot, create an `unattend.xml` and place it at `C:\Windows\System32\Sysprep\unattend.xml` before running Sysprep.

See [unattend.xml Reference](#unattendxml-reference) for the full template.

For golden images, the key sections are:

- **specialize pass** — Sets `ComputerName` (use a placeholder like `GOLDEN-CLONE`)
- **FirstLogonCommands** — Runs `netsh`/PowerShell to configure static IP, gateway, DNS
- **OOBE pass** — Skips all OOBE screens, enables auto-logon

---

### Step 10: Run Sysprep

```powershell
# Inside the Windows VM:
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /mode:vm
```

This:
- Resets the SID (prevents conflicts between clones)
- Clears the hostname and network settings
- Triggers OOBE on next boot
- Shuts down the VM

**Important:** Windows allows only 3 re-arm cycles by default. Track your Sysprep usage. To reset the counter:

```powershell
# Modify registry key:
# HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Setup\Rearm
```

---

### Step 11: Create a DataSource

After Sysprep shuts down the VM, create a DataSource from the data disk PVC so clones can reference it:

```bash
oc apply -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: windows-golden-image-v1
  namespace: openshift-virtualization-os-images
spec:
  source:
    pvc:
      namespace: virt-windows
      name: <vm-name>-data
EOF
```

---

### Step 12: Clone the Golden Image

#### Option A: Web Console

1. Open OpenShift Virtualization console
2. Navigate to **VirtualMachines** → find your golden VM
3. Click **Clone** → enter new VM name → click **Create**

#### Option B: CLI — Generate New Manifest

```bash
# Generate a new VM manifest
./scripts/create-vm.sh \
  --name win11-clone-01 \
  --namespace virt-windows \
  --data-size 60Gi

# Edit the generated YAML: replace the data disk source from blank to the DataSource:
# Change:
#   source:
#     blank: {}
# To:
#   sourceRef:
#     kind: DataSource
#     name: windows-golden-image-v1
#     namespace: openshift-virtualization-os-images

# Apply
oc apply -f win11-clone-01.yaml -n virt-windows
oc start vm/win11-clone-01 -n virt-windows
```

#### Option C: CLI — PVC Clone (Manual)

```bash
# Create a new DataVolume that clones from the DataSource
oc apply -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: win11-clone-01-data
  namespace: virt-windows
  annotations:
    cdi.kubevirt.io/storage.bind.immediate.requested: "true"
spec:
  sourceRef:
    kind: DataSource
    name: windows-golden-image-v1
    namespace: openshift-virtualization-os-images
  storage:
    resources:
      requests:
        storage: 60Gi
    accessModes:
      - ReadWriteOnce
    storageClassName: nfs-csi
EOF
```

Then create a VM manifest referencing the cloned PVC.

---

### Step 13: Verify the Clone

```bash
# Check VMI status
oc get vmi/win11-clone-01 -n virt-windows

# Check interface IP (requires QEMU guest agent)
oc get vmi/win11-clone-01 -o jsonpath='{.status.interfaces[0].ipAddress}'

# Verify guest OS info
oc get vmi/win11-clone-01 -o jsonpath='{.status.guestOSInfo}'
```

---

### Important Notes

**MAC Address on Clones:** When cloning via CLI, **remove the `macAddress` field** from `spec.template.spec.domain.devices.interfaces`. Leaving the original MAC causes `Failed to allocate mac to the vm object` errors. Let KubeVirt auto-assign a new MAC.

**Versioning DataSources:** Use versioned DataSource names to track golden image revisions:

```
windows-golden-image-v1   →  Base image, July 2026
windows-golden-image-v2   →  Added application X, security patches
windows-golden-image-v3   →  Updated to Windows 11 25H2
```

---

## unattend.xml Reference

For fully automated Windows installation without manual input. Attach as a CD-ROM alongside the Windows ISO and VirtIO ISO.

### Quick Start

```bash
# 1. Copy and edit the template
cp templates/autounattend.xml.example autounattend.xml
# Edit: hostname, password, IP, Windows edition

# 2. Build ISO
genisoimage -o autounattend.iso -J -l -no-emul-boot autounattend.xml

# 3. Upload as DataVolume
oc apply -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: autounattend-iso
  namespace: virt-windows
  annotations:
    cdi.kubevirt.io/storage.bind.immediate.requested: "true"
spec:
  storage:
    resources:
      requests:
        storage: 1Gi
    accessModes:
      - ReadWriteMany
    storageClassName: nfs-csi
  source:
    upload: {}
EOF

virtctl image-upload dv autounattend-iso \
  --size=1G \
  --image-path=autounattend.iso \
  --insecure \
  --force-bind \
  -n virt-windows
```

### Add to VM Manifest

Add a fourth disk entry alongside the Windows ISO, VirtIO ISO, and data disk:

```yaml
spec:
  template:
    spec:
      domain:
        devices:
          disks:
            # ... existing disks ...
            - name: autounattend-iso
              cdrom:
                bus: sata
      volumes:
        # ... existing volumes ...
        - name: autounattend-iso
          dataVolume:
            name: autounattend-iso
```

### Key Fields to Customize

| Field | Location | Purpose |
|---|---|---|
| `ComputerName` | specialize pass | Sets the hostname |
| `ProductKey` | windowsPE + specialize | Windows license key |
| `<Value>` under ImageInstall | windowsPE pass | Which Windows edition to install |
| `AdministratorPassword` | oobeSystem pass | Admin account password |
| `New-NetIPAddress` | FirstLogonCommands | Static IP, gateway, DNS |
| `NetKVM` path | FirstLogonCommands | VirtIO network driver path |

### Windows Version Paths for VirtIO Drivers

| OS | viostor path | NetKVM path |
|---|---|---|
| Server 2025 | `viostor\2k25\amd64\` | `NetKVM\2k25\amd64\` |
| Server 2022 | `viostor\2k22\amd64\` | `NetKVM\2k22\amd64\` |
| Server 2019 | `viostor\2k19\amd64\` | `NetKVM\2k19\amd64\` |
| Windows 11 | `viostor\w11\amd64\` | `NetKVM\w11\amd64\` |
| Windows 10 | `viostor\w10\amd64\` | `NetKVM\w10\amd64\` |

### Network Configuration

With the default masquerade network, the VM gets an IP via DHCP from KubeVirt's DHCP server. To set a static IP, add a `FirstLogonCommand`:

```xml
<SynchronousCommand wcm:action="add">
  <Order>2</Order>
  <CommandLine>powershell -Command "New-NetIPAddress -InterfaceAlias 'Ethernet 2' -IPAddress 10.0.0.100 -PrefixLength 24 -DefaultGateway 10.0.0.1; Set-DnsClientServerAddress -InterfaceAlias 'Ethernet 2' -ServerAddresses 10.0.0.1, 8.8.8.8"</CommandLine>
  <Description>Configure Static IP</Description>
</SynchronousCommand>
```

For bridge/multus networks (like `vlan-60`), the interface name may differ. Check with `Get-NetAdapter` after first boot.

### Finding the VM IP After Boot

```bash
oc get vmi <vm-name> -o jsonpath='{.status.interfaces[0].ipAddress}'
```

---

## Automation (still need to validate)

### Script: `create-vm.sh`

Generate VirtualMachine YAML for Windows guests:

```bash
./scripts/create-vm.sh \
  --name win11-dev-01 \
  --namespace virt-windows \
  --template windows11 \
  --instancetype u1.large \
  --data-size 100Gi \
  --network default/vlan-60 \
  --mac 02:f2:1a:73:a8:65

oc apply -f win11-dev-01.yaml
oc start vm/win11-dev-01 -n virt-windows
```

**Options:**

| Flag | Description | Default |
|------|-------------|---------|
| `--name` | VM name (required) | — |
| `--namespace` | Target namespace | `virt-windows` |
| `--template` | OS template: `windows11`, `windows2025` | `windows11` |
| `--instancetype` | KubeVirt instance type | `u1.large` |
| `--data-size` | Data disk size | `100Gi` |
| `--storage-class` | StorageClass name | `nfs-csi` |
| `--network` | NetworkAttachmentDef ns/name | `default/vlan-60` |
| `--mac` | Static MAC address | auto-generated |
| `--run-strategy` | Run strategy | `RerunOnFailure` |
| `--output` | Output file | `{name}.yaml` |
| `--dry-run` | Print to stdout | — |

### Ansible Playbook

Fully automated pipeline: unattend.xml generation → ISO creation → VM deployment → Windows installation → post-install configuration.

**Architecture:**

```
Phase 1: PROVISION (localhost)
  1. Generate unattend.xml from Jinja2 template
  2. Create ISO with podman + genisoimage
  3. Upload ISO to cluster as DataVolume
  4. Clone Windows ISO DataSource
  5. Create blank data disk DataVolume
  6. Create VirtualMachine with all disks attached
  7. Start VM + inject boot keypress

Phase 2: WAIT (localhost)
  8.  Wait for VMI to be Running
  9.  Get VM IP address
  10. Wait for WinRM port 5985

Phase 3: CONFIGURE (WinRM → Windows VM)
  11. Verify Windows version
  12. Install virtio drivers
  13. Run Windows Update
  14. Reboot if needed
  15. Configure power plan, disable hibernation
```

**Prerequisites:**

- Ansible 2.15+ with `ansible.windows`, `kubernetes.core`, `community.general`
- `oc` CLI with access to OpenShift cluster
- `podman` for ISO creation
- KubeVirt + CDI installed on cluster

**Configuration:**

Edit `ansible/group_vars/all.yml`:

| Variable | Default | Description |
|----------|---------|-------------|
| `vm_name` | `win11-auto-01` | VM name |
| `vm_instancetype` | `u1.large` | Instance type |
| `vm_preference` | `windows.11.virtio` | KubeVirt preference |
| `vm_data_size` | `100Gi` | Data disk size |
| `vm_network` | `default/vlan-60` | Network attachment |
| `vm_mac` | `02:f2:1a:73:a8:66` | MAC address (unique per VM) |
| `windows_admin_password` | `P@ssw0rd1234!` | Administrator password |
| `windows_computer_name` | derived from vm_name | Hostname |

**Usage:**

```bash
cd ansible

# Full pipeline (provision + wait + configure)
ansible-playbook site.yml

# Provision only
ansible-playbook site.yml --tags provision

# Configure only (after VM is running)
ansible-playbook site.yml --tags configure
```

**Files:**

| Path | Purpose |
|------|---------|
| `ansible/site.yml` | Main playbook (3 phases) |
| `ansible/roles/windows-provision/` | VM provisioning role |
| `ansible/roles/windows-configure/` | Post-install configuration role |
| `ansible/roles/windows-provision/templates/unattend.xml.j2` | Jinja2 unattend template |
| `ansible/roles/windows-provision/files/key_injector.py` | Console keypress injection |
| `ansible/group_vars/all.yml` | Cluster and VM configuration |
| `ansible/inventory.yml` | Ansible inventory |

---

## Templates

| Template | OS | DataSource | Min Disk |
|----------|-----|------------|----------|
| `windows11` | Windows 11 25H2 | `windows-11-25h2-amd64` | 30Gi |
| `windows2025` | Windows Server 2025 | `windows-2025-virtio-amd64` | 30Gi |

---

## Troubleshooting

### VM won't detect the data disk during Windows Setup

Load the virtio storage driver manually:
1. At the disk selection screen, click **Load Driver**
2. Browse to the virtio-drivers CD-ROM
3. Navigate to `viostor\w11\amd64\` (or your Windows version)
4. Select the driver and continue

### "Failed to allocate mac to the vm object"

The cloned VM has the same `macAddress` as the source. Remove the `macAddress` field from the clone's interface definition and let KubeVirt auto-assign.

### DataVolume stuck in PendingPopulation

Add the annotation `cdi.kubevirt.io/storage.bind.immediate.requested: "true"` to the DataVolume metadata, or use `--force-bind` with `virtctl image-upload`.

### Sysprep fails with "The sysprep parameter generalize can only be used on a depooled generalization image"

Run `slmgr /dlv` to check your re-arm count. Windows allows 3 re-arm cycles by default. Modify the registry key `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Setup\Rearm` to reset.

### VM console shows "Press any key to boot from CD"

The Ansible playbook includes automatic key injection via `key_injector.py`. If running manually, connect quickly and press a key, or use `virtctl console` and send a keypress.

---

## References

- [OpenShift Virtualization Documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/virtualization/index)
- [KubeVirt Documentation](https://kubevirt.io/userguide/)
- [Windows unattend.xml Schema Reference](https://learn.microsoft.com/windows-hardware/manufacture/desktop/update-windows-settings-and-scripts-create-your-own-answer-file-sxs)
- [VirtIO Drivers for Windows](https://fedoraproject.org/wiki/Windows_Virtio_Drivers)
