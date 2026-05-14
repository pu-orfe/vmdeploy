# Project Overview: Azure VM Deployment Toolkit

This project is a comprehensive toolkit for deploying and managing secure Linux (Ubuntu 22.04) VMs on Azure. It prioritizes security, automation, and ease of use, providing scripts for infrastructure provisioning, data transfer, and security configuration.

## Key Technologies
- **Azure CLI (`az`)**: Primary interface for interacting with Azure resources.
- **Bicep**: Infrastructure as Code (IaC) for defining Azure resources (`main.bicep`).
- **Bash**: Scripting language used for deployment and management automation.
- **Cloud-init**: Industry-standard tool for cross-platform cloud instance initialization (`cloud-init.yaml`).
- **azcopy**: High-performance tool for copying data to and from Azure Blob storage.
- **Postfix**: Used for sending system-level alert emails.

## Core Components
- **`deploy.sh`**: The main deployment script. Handles resource group creation, Bicep template deployment, and Entra ID role assignments.
- **`transfer.sh`**: Facilitates data transfer from a local machine to the Azure VM using temporary Blob Storage as an intermediary.
- **`main.bicep`**: Defines the infrastructure, including VM, NSG, Public IP, Storage Account, and Key Vault.
- **`cloud-init.yaml`**: Configures the OS, including auto-updates, service users, and failure notification scripts.
- **`configure-security-contacts.sh`**: Sets up subscription-level security contacts.
- **`move-subscription.sh`**: Script to move the deployed resource group to another subscription.

## Building and Running

### Deployment
To deploy a new VM or update an existing one:
```bash
./deploy.sh -g <resource-group-name> -n <vm-name> -e <alert-email> [OPTIONS]
```
Common options:
- `--parameters <file.json>`: Use a custom parameters file.
- `--entra-admin <email>`: Grant admin access via Entra ID.
- `--entra-user <email>`: Grant standard access via Entra ID.
- `--dry-run`: Preview changes without applying them.

### Data Transfer
To transfer files to the VM:
```bash
./transfer.sh -g <resource-group-name> -n <vm-name> -t <local-path>:<vm-path>
```

### Resource Deletion
To tear down all resources in a resource group:
```bash
./deploy.sh -g <resource-group-name> --destroy
```

### Testing
Verify the security configuration of the Bicep templates and scripts:
```bash
./tests/test-security.sh
```

## Development Conventions

- **Scripting Standards**: Bash scripts use `set -euo pipefail` for robust error handling.
- **Security First**: 
    - SSH is blocked by default; access is encouraged via Azure Serial Console or Run Command.
    - Entra ID (Azure AD) authentication is integrated for RBAC.
    - Customer-managed keys (CMK) are enabled by default for disk encryption.
- **Configuration**: Use `parameters.json` to customize project-specific settings like inbound ports and service users.
- **Testing**: New security features or infrastructure changes should be validated by adding tests to `tests/test-security.sh`.
- **Documentation**: Keep `README.md` and `SMTP-SETUP.md` updated with any significant changes to the deployment process or requirements.

## Example Projects: HFM (High-Frequency Market data)

The `hfm` configuration (`~/Downloads/hfm-config`) is a reference implementation for a kdb+/q time-series database. It demonstrates advanced use of the toolkit:

- **Custom Infrastructure**: Uses `parameters.hfm.json` to define a specific port range (6000-6007) with restricted access for kdb+ IPC connections.
- **Service Management**:
    - **Systemd User Services**: Employs `systemd --user` to manage Q processes under a non-root `hfm` user.
    - **Watchdog Script**: Includes `qservice.sh` to monitor and restart individual Q daemons.
    - **Resilience**: Uses `loginctl enable-linger` to ensure services start on boot and persist after logout.
- **Administration**:
    - **Service Admins**: Grants specific Entra ID users the ability to manage the `hfm` service via `machinectl` and `sudo` rules.
    - **Aliases**: Provides an `hfm` alias for seamless switching to the service user's shell.
- **Licensing Compliance**: Sets canonical FQDN (`hfm.princeton.edu`) via cloud-init, which is often required for software licenses.

### HFM Deployment Command
```bash
./deploy.sh \
  -g orfe-dept-azure-rfa-hfm-rg \
  -n hfm-vm \
  -e orfeit@princeton.edu \
  --cloud-init ~/Downloads/hfm-config/cloud-init.hfm.yaml \
  --parameters ~/Downloads/hfm-config/parameters.hfm.json \
  --service-admin bino@princeton.edu
```

## Cost Management & IP Retention

If you need to stop incurring compute costs for a VM (e.g., between projects) but want to **retain the Public IP address** and avoid updating DNS records, use the "Parking Strategy":

### 1. Deallocate the VM
Instead of using `--destroy`, deallocate the VM via the Azure CLI. This stops the billing for CPU and RAM while keeping the disks and Static IP intact.
```bash
az vm deallocate -g <resource-group> -n <vm-name>
```

### 2. What happens to costs?
- **Compute (CPU/RAM)**: $0 (Billing stops immediately).
- **Public IP**: You will still be charged a small monthly fee for the reserved Static IP (~$4/month).
- **Storage (Disks)**: You will continue to be charged for the Managed Disks (OS and Data disk) at standard rates.

### 3. Resuming Service
When you are ready to use the VM again, simply start it:
```bash
az vm start -g <resource-group> -n <vm-name>
```
The VM will boot up with the **same Public IP address** and all data preserved.

---

## Troubleshooting
- **Admin Password**: If the initial admin password fails, use `az vm user update` to reset it.
- **Data Transfer**: Ensure you have the `Storage Blob Data Contributor` role if `transfer.sh` fails with SAS token errors.
