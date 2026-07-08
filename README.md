# OpenShift VM Templates

Windows VirtualMachine templates, provisioning scripts, and automation for OpenShift Virtualization.

## Contents

- [Manual VM Creation](#manual-vm-creation) — Script or hand-crafted YAML
- [Ansible Automation](#ansible-automation) — Fully automated provisioning + configuration
- [Golden Image Workflow](#golden-image-workflow) — Build a golden image, then clone for rapid deployment
- [unattend.xml Reference](#unattendxml-reference) — Manual autounattend.xml creation for automated Windows install
- [Cluster Reference](CLUSTER_REFERENCE.md) — Cluster-specific values (luke)

---

## Quick Start

### Option A: Script (manual creation)

```bash
# Generate a Windows 11 VM manifest
./scripts/create-vm.sh \
  --name win11-dev-01 \
  --namespace virt-windows \
  --instancetype u1.large \
  --data-size 100Gi \
  --network default/vlan-60 \
  --mac 02:f2:1a:73:a8:65

# Apply and start
oc apply -f win11-dev-01.yaml
oc start vm/win11-dev-01 -n virt-windows
```

### Option B: Ansible (fully automated)

```bash
# Configure variables in ansible/group_vars/all.yml
# Then run the full pipeline:
cd ansible
ansible-playbook site.yml
```

### Option C: Golden Image + Clone

See [Golden Image Workflow](#golden-image-workflow) for building a base image and cloning it for rapid deployment.

---

## Manual VM Creation

### Script Options

See `./scripts/create-vm.sh --help`. Key parameters:

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

### Architecture

Each VM uses a two-disk pattern:

1. **Boot volume** — Cloned from the OS DataSource (30Gi). Attached as CD-ROM during install.
2. **Data volume** — Blank disk (configurable size). The guest OS is installed here.
3. **Virtio drivers** — containerDisk. Provides network, storage, and balloon drivers.

### Prerequisites

Verify the cluster has the required resources:

```bash
# DataSource
oc get datasource windows-11-25h2-amd64 -n openshift-virtualization-os-images

# Instance type and preference
oc get virtualmachineclusterinstancetype u1.large
oc get virtualmachineclusterpreference windows.11.virtio

# Network
oc get network-attachment-definition vlan-60 -n default

# Storage
oc get storageclass nfs-csi
```

### Step-by-Step

#### Step 1: Generate Unique Identifiers

```bash
# Firmware UUID
VM_UUID=$(cat /proc/sys/kernel/random/uuid)

# Firmware serial
VM_SERIAL=$(cat /proc/sys/kernel/random/uuid)

# MAC address (locally-administered, OUI 02:F2:1A)
VM_MAC="02:f2:1a:73:a8:65"
```

#### Step 2: Create the VirtualMachine Manifest

Use `./scripts/create-vm.sh` or create YAML by hand. See `templates/windows11-vm.yaml` for a reference template.

**Key fields to customize:**

| Field | Purpose | Example |
|---|---|---|
| `metadata.name` | VM name | `win11-dev-01` |
| `spec.dataVolumeTemplates[*].name` | Must match `<vm-name>-boot` and `<vm-name>-data` | `win11-dev-01-boot` |
| `firmware.uuid` / `firmware.serial` | Unique per VM | Output from Step 1 |
| `interfaces[0].macAddress` | Static MAC (optional) | `02:f2:1a:73:a8:65` |
| `networks[0].multus.networkName` | NetworkAttachmentDef ref | `default/vlan-60` |

#### Step 3: Apply and Start

```bash
oc apply -f win11-dev-01.yaml -n virt-windows

# Wait for DataVolumes
oc get datavolume -n virt-windows -w

# Start the VM
oc start vm/win11-dev-01 -n virt-windows
```

#### Step 4: Connect and Install

```bash
# noVNC console
oc virt-launcher-console win11-dev-01 -n virt-windows

# SPICE URL for virt-viewer
oc virt-launcher-spice-url win11-dev-01 -n virt-windows
```

1. VM boots from Windows ISO (bootOrder 2, CD-ROM)
2. Blank data disk (bootOrder 1) is the installation target
3. If Windows does not detect the disk, load virtio storage drivers from `windows-drivers-disk` CD-ROM:
   - Click **Load Driver** → browse to `viostor` folder → select driver for your Windows version
4. Complete Windows installation
5. After reboot, install remaining virtio drivers (network, balloon, QEMU guest agent)

#### Step 5: Verify

```bash
# Check VMI status
oc get vmi/win11-dev-01 -n virt-windows

# Check interface IP (requires QEMU guest agent)
oc describe vmi/win11-dev-01 -n virt-windows | grep -A5 "Interfaces:"

# Take a snapshot for backup
oc create volumesnapshot win11-dev-01-snapshot \
  --source=pvc/win11-dev-01-data -n virt-windows
```

---

## Ansible Automation

Fully automated Windows provisioning pipeline: unattend.xml generation → ISO creation → VM deployment → Windows installation → post-install configuration.

### Architecture

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

### Prerequisites

- Ansible 2.15+ with `ansible.windows`, `kubernetes.core`, `community.general`
- `oc` CLI with access to OpenShift cluster
- `podman` for ISO creation
- KubeVirt + CDI installed on cluster
- Windows ISO DataSource available in `openshift-virtualization-os-images`

### Configuration

Edit `ansible/group_vars/all.yml`:

| Variable | Default | Description |
|----------|---------|-------------|
| `vm_name` | `win11-auto-01` | VM name |
| `vm_instancetype` | `u1.large` | Instance type |
| `vm_preference` | `windows.11.virtio` | KubeVirt preference |
| `vm_data_size` | `100Gi` | Data disk size |
| `vm_network` | `default/vlan-60` | Network attachment |
| `vm_mac` | `02:f2:1a:73:a8:66` | MAC address (unique per VM) |
| `vm_uuid` | auto-generated | VM firmware UUID |
| `windows_admin_password` | `P@ssw0rd1234!` | Administrator password |
| `windows_language` | `en-US` | Windows language |
| `windows_timezone` | `UTC` | Timezone |
| `windows_edition` | `Windows 11 Pro` | Edition to install from ISO |
| `windows_computer_name` | derived from vm_name | Hostname |

### Usage

```bash
cd ansible

# Full pipeline (provision + wait + configure)
ansible-playbook site.yml

# Provision only
ansible-playbook site.yml --tags provision

# Configure only (after VM is running)
ansible-playbook site.yml --tags configure
```

### Files

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

## Golden Image Workflow

Build a fully configured Windows VM, generalize it with Sysprep, then clone it to deploy identical VMs in seconds.

### When to Use

- Deploying multiple identical Windows VMs (dev/test environments, CI agents, training systems)
- Pre-installing applications, patches, and configurations
- Reducing per-VM provisioning time from ~15 minutes to ~30 seconds

### Prerequisites

- A working Windows VM (created via the Manual or Ansible workflows above)
- StorageClass that supports volume cloning (`nfs-csi` does)
- `virtctl` CLI installed

### Phase 1: Build the Base VM

1. **Create the VM** using the script, Ansible, or manual YAML from above.
2. **Install Windows** via the console.
3. **Install applications** and configure the system as desired.
4. **Install QEMU Guest Agent** from the virtio-drivers CD-ROM (`qemu-ga-x86_64.msi`).

### Phase 2: Create unattend.xml (Optional)

If you want clones to automatically configure hostname and network on first boot, create an `unattend.xml` and place it at `C:\Windows\System32\Sysprep\unattend.xml` before running Sysprep.

See [unattend.xml Reference](#unattendxml-reference) for the full template.

For golden images, the key sections are:

- **specialize pass** — Sets `ComputerName` (use a placeholder like `GOLDEN-CLONE`)
- **FirstLogonCommands** — Runs `netsh` to configure static IP, gateway, DNS
- **OOBE pass** — Skips all OOBE screens, enables auto-logon

### Phase 3: Run Sysprep

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
REM HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Setup\Rearm
```

### Phase 4: Create a DataSource

After Sysprep shuts down the VM, create a DataSource from the data disk PVC so clones can reference it:

```bash
# Create the DataSource
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
      name: win11-golden-data
EOF
```

### Phase 5: Clone the Golden Image

#### Option A: Web Console

1. Open OpenShift Virtualization console
2. Navigate to **VirtualMachines** → find your golden VM
3. Click **Clone** → enter new VM name → click **Create**

#### Option B: CLI

```bash
# Create a new VM manifest that clones from the DataSource
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

#### Option C: PVC Clone (manual)

```bash
# Clone the PVC directly
oc patch pvc win11-golden-data \
  --type='json' \
  -p='[{"op":"add","path":"/metadata/name","value":"win11-clone-01-data"}]' \
  -n virt-windows

# Or create a new PVC with dataSource
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

### Important: MAC Address on Clones

When cloning via CLI, **remove the `macAddress` field** from `spec.template.spec.domain.devices.interfaces`. Leaving the original MAC causes `Failed to allocate mac to the vm object` errors. Let KubeVirt auto-assign a new MAC.

### Versioning DataSources

Use versioned DataSource names to track golden image revisions:

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
# 1. Create the file (see template below)
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

### Password Encoding

The unattend.xml template in `ansible/roles/windows-provision/templates/unattend.xml.j2` uses plaintext passwords with `<PlainText>true</PlainText>` (supported on modern Windows versions). For encoded passwords:

```powershell
# On any Windows machine with Windows ADK, or via this approach:
# The Ansible role handles this automatically.
```

### Network Configuration

With the default masquerade network, the VM gets an IP via DHCP from KubeVirt's DHCP server. To set a static IP, add a `FirstLogonCommand` with `netsh`:

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
