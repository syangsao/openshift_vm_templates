# Ansible Windows VM Automation

Fully automated Windows 11 provisioning on OpenShift Virtualization.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Phase 1: PROVISION (localhost)                             │
│  ┌───────────────────────────────────────────────────────┐   │
│  │ 1. Generate unattend.xml from Jinja2 template         │   │
│  │ 2. Create ISO with podman + mkisofs                   │   │
│  │ 3. Upload ISO to cluster as DataVolume                │   │
│  │ 4. Clone Windows ISO DataSource                       │   │
│  │ 5. Create blank data disk DataVolume                  │   │
│  │ 6. Create VirtualMachine with all disks attached      │   │
│  │ 7. Start VM                                           │   │
│  └───────────────────────────────────────────────────────┘   │
│                                                              │
│  Phase 2: WAIT (localhost)                                  │
│  ┌───────────────────────────────────────────────────────┐   │
│  │ 8. Wait for VMI to be Running                         │   │
│  │ 9. Get VM IP address                                  │   │
│  │ 10. Wait for WinRM port 5985                          │   │
│  └───────────────────────────────────────────────────────┘   │
│                                                              │
│  Phase 3: CONFIGURE (WinRM → Windows VM)                    │
│  ┌───────────────────────────────────────────────────────┐   │
│  │ 11. Verify Windows version                            │   │
│  │ 12. Install virtio drivers                            │   │
│  │ 13. Run Windows Update                                │   │
│  │ 14. Reboot if needed                                  │   │
│  │ 15. Configure power plan, disable hibernation         │   │
│  └───────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Ansible 2.15+ with `ansible.windows`, `kubernetes.core`, `community.general`
- `oc` CLI with access to OpenShift cluster
- `podman` for ISO creation
- KubeVirt + CDI installed on cluster
- Windows 11 ISO DataSource available in `openshift-virtualization-os-images`

## Configuration

Edit `group_vars/all.yml` to customize:

| Variable | Default | Description |
|----------|---------|-------------|
| `vm_name` | `win11-auto-01` | VM name |
| `vm_instancetype` | `u1.large` | KubeVirt instance type |
| `vm_preference` | `windows.11.virtio` | KubeVirt preference |
| `vm_data_size` | `100Gi` | Blank data disk size |
| `vm_network` | `default/vlan-60` | Network attachment |
| `vm_mac` | `02:f2:1a:73:a8:66` | MAC address (unique per VM) |
| `vm_uuid` | auto-generated | VM UUID (unique per VM) |
| `windows_admin_password` | `P@ssw0rd1234!` | Administrator password |
| `windows_language` | `en-US` | Windows language |
| `windows_timezone` | `UTC` | Windows timezone |

## Usage

```bash
# Run full pipeline (provision + wait + configure)
ansible-playbook site.yml

# Run only provisioning phase
ansible-playbook site.yml --tags provision

# Run only configuration phase (after VM is running)
ansible-playbook site.yml --tags configure
```

## unattend.xml

The `unattend.xml.j2` template configures:

- **Windows PE phase:** Disk partitioning, Windows installation from ISO
- **Specialize phase:** Computer name, RDP enablement, firewall rules
- **OOBE phase:** Administrator account, auto-logon, WinRM enablement, virtio driver install, Windows Update

## Files

- `site.yml` — Main playbook (3 phases)
- `roles/windows-provision/` — VM provisioning role
- `roles/windows-configure/` — Post-install configuration role
- `group_vars/all.yml` — Cluster and VM configuration
- `inventory.yml` — Ansible inventory
