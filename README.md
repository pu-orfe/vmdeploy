# Azure VM Deployment

A reusable Azure deployment script for Linux VMs with Entra ID authentication, Serial Console access, and metric alerts.

## Overview

This deployment script provisions:
- Ubuntu 22.04 VM with configurable size
- Premium SSD data disk
- Network security (SSH blocked, configurable port access)
- Entra ID (Azure AD) authentication for Serial Console
- Metric alerts (availability, CPU, memory)
- Auto-updates with unattended-upgrades

## When Not to Use

This script is pragmatic for simple, single-user deployments. Consider alternatives like Terraform, Pulumi, or Azure DevOps/GitHub Actions pipelines if you need:

- **State tracking** - Know what's deployed vs. what's defined
- **Drift detection** - Catch manual changes made outside of code
- **Rollback** - Revert to previous infrastructure versions
- **Team collaboration** - State locking, remote state, PR reviews
- **Testing** - Validate before deploy, policy checks (OPA, Azure Policy)
- **Secrets management** - Azure Key Vault integration instead of prompts

## Prerequisites

- Azure CLI installed (`az`)
- jq installed (for parsing deployment output)
- Logged in to Azure (`az login`)

## Quick Start

```bash
# Deploy with required parameters
./deploy.sh \
    -g my-resource-group \
    -n my-vm \
    -e alerts@example.com

# With Entra ID access (recommended)
./deploy.sh \
    -g my-resource-group \
    -n my-vm \
    -e alerts@example.com \
    --entra-admin admin@example.com \
    --entra-user user1@example.com \
    --entra-user user2@example.com

# With service admins (can manage application without root)
./deploy.sh \
    -g my-resource-group \
    -n my-vm \
    -e alerts@example.com \
    --parameters ./parameters.json \
    --service-admin operator1@example.com \
    --service-admin operator2@example.com

# With custom VM options
./deploy.sh \
    -g my-resource-group \
    -n my-vm \
    -e alerts@example.com \
    -l westus2 \
    -s Standard_D4s_v5 \
    -d 128 \
    --entra-admin admin@example.com

# With custom templates (for reuse in other projects)
./deploy.sh \
    -g my-project \
    -n my-vm \
    -e alerts@example.com \
    --bicep /path/to/custom.bicep \
    --cloud-init /path/to/custom-cloud-init.yaml \
    --role-definition /path/to/custom-role.json

# Dry run to preview deployment
./deploy.sh \
    -g my-resource-group \
    -n my-vm \
    -e alerts@example.com \
    --dry-run
```

The script will prompt for an admin password (used for Serial Console access).

## Deploy Options

| Option | Description |
|--------|-------------|
| `-g, --resource-group` | Azure resource group name (required) |
| `-n, --name` | VM name (required for deploy) |
| `-e, --email` | Email for failure notifications (required) |
| `-l, --location` | Azure region (default: canadacentral) |
| `-s, --size` | VM size (default: Standard_D8s_v5) |
| `-d, --disk-size` | Data disk size in GB (default: 64) |
| `--entra-admin` | Entra ID user with admin/sudo access |
| `--entra-user` | Entra ID user with standard access (repeatable) |
| `--service-admin EMAIL` | Entra ID user who can act as service user (repeatable) |
| `--dry-run` | Show what would happen without making changes |
| `--deallocate` | Stop VM and release compute (retains IP/disks) |
| `--destroy` | Tear down all resources |
| `--bicep FILE` | Custom Bicep template (default: ./main.bicep) |
| `--cloud-init FILE` | Custom cloud-init YAML (default: ./cloud-init.yaml) |
| `--parameters FILE` | Parameters JSON for ports, project name, etc. |
| `--role-definition FILE` | Custom role definition JSON for `--entra-user` |

## In-Place Updates

When you run `deploy.sh` against an existing resource group, you'll be prompted to choose:

- **Update in-place (u)**: Preserves public IP, DNS name, and data disk. Updates VM size, NSG rules, alerts, and Entra ID roles.
- **Delete and recreate (d)**: Destroys everything and starts fresh (loses all data).

```bash
# Running against existing deployment prompts for action
./deploy.sh -g my-resource-group -n my-vm -e alerts@example.com

# Output:
# Resource group 'my-resource-group' already exists.
# Options:
#   u) Update in-place - preserve public IP/DNS, update VM config (recommended)
#   d) Delete and recreate - destroys everything including data disk
#   c) Cancel
```

**What gets updated in-place:**
- VM size (may require restart)
- NSG inbound port rules
- Alert configurations
- Entra ID role assignments

**What is NOT changed:**
- Public IP address and DNS name
- Data disk contents
- Admin password
- Cloud-init configuration (use `transfer.sh` for file updates)

This makes it safe to set up a CNAME pointing to your VM's FQDN - the DNS name will survive updates.

## Tear Down & Parking

### Stop and Deallocate (Save costs, retain IP)
Use this to stop compute billing while keeping your IP and disk data.
```bash
./deploy.sh -g my-resource-group -n my-vm --deallocate
```

### Full Destroy
Use this to permanently remove all resources.
```bash
./deploy.sh -g my-resource-group --destroy
```

## What Gets Deployed

| Resource | Purpose |
|----------|---------|
| Ubuntu 22.04 VM | D8s_v5 (8 vCPU, 32GB RAM) by default |
| Premium SSD | Data disk (64GB default) |
| NSG | Network security rules |
| Public IP | Static IP with DNS name |
| Action Group | Email alerts for failures |
| Metric Alerts | VM availability, CPU, memory |
| AADSSHLoginForLinux | Entra ID authentication (if `--entra-admin` or `--entra-user` specified) |

## Security

- **SSH Port**: Blocked at firewall level by default
- **Console Access**: Azure Portal Serial Console or Run Command (RBAC-authenticated)
- **Entra ID Login**: Optional - allows users to authenticate with their Entra credentials
- **Disk Encryption**: Customer-managed keys (CMK) with encryption at host (enabled by default)
- **Storage**: Shared key access disabled; uses Entra ID authentication only
- **Key Vault**: Diagnostic logging enabled for audit compliance
- **Guest Configuration**: Azure Policy guest configuration extension installed

### Azure Secure Score Compliance

This deployment addresses the following Azure Security Center recommendations:

| Recommendation | How Addressed |
|----------------|---------------|
| Guest Configuration extension should be installed | AzurePolicyforLinux extension auto-installed |
| Storage accounts should prevent shared key access | Not addressed - shared key required for Serial Console |
| Linux VMs should enable Azure Disk Encryption or EncryptionAtHost | `encryptionAtHost: true` when CMK enabled |
| Diagnostic logs in Key Vault should be enabled | Log Analytics workspace with audit logs configured |

### Subscription-Level Security Settings

Some security recommendations require subscription-level configuration. Use the provided script:

```bash
# Configure security contact for the subscription
./configure-security-contacts.sh -e security@example.com

# With phone number
./configure-security-contacts.sh -e security@example.com --phone "+1-555-123-4567"

# Dry run to preview
./configure-security-contacts.sh -e security@example.com --dry-run
```

This addresses:
- Email notification to subscription owner for high severity alerts
- Subscriptions should have a contact email address for security issues
- Email notification for high severity alerts should be enabled

### Guest Accounts

The recommendation "Guest accounts with read permissions on Azure resources should be removed" requires manual review:

```bash
# List guest users in your Entra ID tenant
az ad user list --filter "userType eq 'Guest'" -o table

# Check role assignments for a specific guest
az role assignment list --assignee "guest@external.com" -o table
```

Remove unnecessary guest access via Azure Portal > Entra ID > Users, or using `az role assignment delete`.

## Console Access

**Serial Console** - Interactive terminal via Azure Portal:
1. Navigate to: VM > Help > Serial console
2. Login with local admin username + password (set during deploy)
3. Or with Entra ID email + password (if `--entra-admin` or `--entra-user` was specified)

**Reset Local Admin Password** - The deployment script may fail to set the admin password correctly. If you cannot log in with the password entered during deployment, reset it:

```bash
az vm user update \
    --resource-group my-resource-group \
    --name my-vm \
    --username <admin-username> \
    --password 'NewPassword123!'
```

Password requirements: minimum 12 characters, must include uppercase, lowercase, number, and special character.

**Run Command** - Execute scripts without credentials:
```bash
az vm run-command invoke \
    --resource-group my-resource-group \
    --name my-vm \
    --command-id RunShellScript \
    --scripts 'hostname && uptime'
```

## Granting User Access

### During Deployment (recommended)

Use `--entra-admin` and `--entra-user` flags to grant access during deployment:

```bash
./deploy.sh -g my-resource-group -n my-vm -e alerts@example.com \
    --entra-admin admin@example.com \
    --entra-user user1@example.com \
    --entra-user user2@example.com
```

- `--entra-admin`: Grants "Virtual Machine Administrator Login" role (has sudo)
- `--entra-user`: Grants custom "Serial Console User" role (minimum permissions for Serial Console only)
- `--service-admin`: Grants Serial Console access PLUS sudoers rules to act as the service user

Users can then login at Serial Console with their Entra ID email and password.

### Service Admins

The `--service-admin` option is designed for users who need to manage a specific service without having full sudo access to the entire system. This is useful for delegating application management (e.g., license updates, service restarts) without granting root access.

```bash
./deploy.sh -g my-resource-group -n my-vm -e alerts@example.com \
    --parameters ./parameters.json \
    --service-admin operator1@example.com \
    --service-admin operator2@example.com
```

You can specify multiple `--service-admin` arguments to grant access to multiple users.

A service admin can:

| Command | What it does |
|---------|--------------|
| `sudo su - <serviceUser>` | Switch to the service user's shell |
| `sudo -u <serviceUser> <command>` | Run any command as the service user |
| `sudo -u <serviceUser> systemctl --user ...` | Control the service user's systemd services |

For example, if `serviceUser` is `hfm` in your parameters file:

```bash
# Switch to hfm user
sudo su - hfm

# Run a command as hfm
sudo -u hfm whoami

# Control hfm's systemd user service
sudo -u hfm systemctl --user restart qservice
```

**Note:** Service admins do NOT have:
- Full sudo/root access
- Access to other users' files or services
- Azure Run Command access (script execution)

This follows the principle of least privilege - operators can manage the application without system-wide root access.

### Post-Deployment

To add users after deployment:

```bash
# Standard user access
az role assignment create \
    --assignee "user@yourdomain.com" \
    --role "Virtual Machine User Login" \
    --scope "/subscriptions/<sub-id>/resourceGroups/my-rg/providers/Microsoft.Compute/virtualMachines/my-vm"

# Admin access (sudo)
az role assignment create \
    --assignee "user@yourdomain.com" \
    --role "Virtual Machine Administrator Login" \
    --scope "/subscriptions/<sub-id>/resourceGroups/my-rg/providers/Microsoft.Compute/virtualMachines/my-vm"
```

**For Run Command access only (no Serial Console login):**
```bash
az role assignment create \
    --assignee "user@yourdomain.com" \
    --role "Virtual Machine Contributor" \
    --scope "/subscriptions/<sub-id>/resourceGroups/my-rg/providers/Microsoft.Compute/virtualMachines/my-vm"
```

## Automated Features

The deployment configures:

**Auto-Updates (unattended-upgrades)**
- Daily security updates
- Weekly full updates
- Automatic reboot at 3:00 AM if required
- Email notifications on update activity

**Failure Notifications**
- Email alerts when VM availability drops
- Email alerts for high CPU (>90%) or low memory (<2GB)

## Configuring Email Notifications

The VM uses postfix for sending alert emails. Configure SMTP relay:

```bash
# Using SendGrid (free tier available in Azure Marketplace)
sudo cat > /etc/postfix/sasl_passwd << 'EOF'
[smtp.sendgrid.net]:587 apikey:YOUR_SENDGRID_API_KEY
EOF

sudo chmod 600 /etc/postfix/sasl_passwd
sudo postmap /etc/postfix/sasl_passwd
sudo systemctl restart postfix

# Test
echo "Test alert" | mail -s "VM Test" your-email@example.com
```

See `SMTP-SETUP.md` for detailed instructions.

## VM Sizing Guide

| Size | vCPU | RAM | Monthly Cost (Est.) |
|------|------|-----|---------------------|
| Standard_D4s_v5 | 4 | 16GB | ~$140 |
| Standard_D8s_v5 | 8 | 32GB | ~$280 |
| Standard_D16s_v5 | 16 | 64GB | ~$560 |

## Data Transfer

The `transfer.sh` script transfers files from your local machine (or HPC) to the Azure VM using temporary Blob Storage as an intermediary. The storage container is automatically deleted after transfer to avoid ongoing costs.

### Quick Start

```bash
# Transfer a directory to the VM
./transfer.sh -g my-resource-group -n my-vm \
    -t ./myapp:/home/appuser

# Transfer multiple paths
./transfer.sh -g my-resource-group -n my-vm \
    -t ./app:/home/appuser \
    -t ./data:/home/appuser/data

# With parameters file (reads serviceUser automatically)
./transfer.sh -g my-resource-group -n my-vm \
    --parameters ./parameters.json \
    -t ./app:/home/appuser

# Dry run to preview
./transfer.sh -g my-resource-group -n my-vm \
    -t ./app:/home/appuser --dry-run
```

### How It Works

1. **Creates temporary container** in the deployment's storage account
2. **Uploads files** from local machine using `azcopy`
3. **Downloads files** to VM using `azcopy` (via Run Command)
4. **Sets ownership** to the service user
5. **Deletes container** automatically (even on error)

### Prerequisites

- `azcopy` installed locally ([installation guide](https://docs.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10))
- VM deployed via `deploy.sh` (uses the boot diagnostics storage account)
- Azure CLI logged in with access to the resource group

### Transfer Options

| Option | Description |
|--------|-------------|
| `-g, --resource-group` | Azure resource group (required) |
| `-n, --name` | VM name (required) |
| `-t, --transfer LOCAL:VM` | Transfer path mapping (repeatable) |
| `--parameters FILE` | Parameters JSON (reads serviceUser) |
| `--service-user USER` | Override service user (default: appuser) |
| `--dry-run` | Preview without transferring |
| `-v, --verbose` | Show detailed progress |

### Example: HFM Database Transfer

For transferring HFM (kdb+/q) application and database files:

```bash
# After deploying with hfm parameters:
./transfer.sh -g hfm-rg -n hfm-vm \
    --parameters ./hfm-parameters.json \
    -t ./hfm:/home/hfm
```

This transfers the entire `./hfm/` directory (including `db/` subdirectory) to `/home/hfm/` on the VM, owned by the `hfm` user.

### Cost Considerations

- **No ongoing costs**: The temporary container is deleted immediately after transfer
- **Transfer costs**: Standard Azure egress/ingress rates apply during transfer
- **Storage during transfer**: Charged at standard blob storage rates (typically pennies)

### Troubleshooting

**"No storage account found"**: Ensure the VM was deployed with `deploy.sh`, which creates a boot diagnostics storage account.

**Slow transfers**: Large databases may take time. Use `-v` for progress. Consider running from a machine closer to Azure (same region).

**Permission errors**: Ensure your Azure CLI login has `Storage Blob Data Contributor` role on the storage account.

## Moving Between Subscriptions

To move resources between subscriptions in the same tenant:

```bash
# Dry run
./move-subscription.sh -g my-resource-group -t "Target-Subscription-Name" --dry-run

# Perform move
./move-subscription.sh -g my-resource-group -t "00000000-0000-0000-0000-000000000000"
```

## Files

| File | Purpose |
|------|---------|
| `deploy.sh` | Main deployment script |
| `transfer.sh` | Post-deploy data transfer script |
| `configure-security-contacts.sh` | Configure subscription security contact settings |
| `main.bicep` | Infrastructure as Code (VM, network, alerts) |
| `cloud-init.yaml` | Generic OS configuration (auto-updates, notifications) |
| `parameters.json` | Template parameters file (customize for your project) |
| `serial-console-user-role.json` | Custom role template for minimum Serial Console permissions |
| `move-subscription.sh` | Script to move resources between subscriptions |
| `SMTP-SETUP.md` | Email configuration guide |

## Parameters File

The `--parameters` option allows you to configure project-specific settings like inbound ports, service user, and project naming. This keeps the deployment script generic and reusable.

### Parameters JSON Structure

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "projectName": {
      "value": "myapp",
      "metadata": { "description": "Short name for storage account (lowercase, no special chars)" }
    },
    "inboundPorts": {
      "value": [
        {
          "name": "Web-Traffic",
          "portRange": "443",
          "sourceAddressPrefixes": ["*"],
          "priority": 1010
        },
        {
          "name": "API-VPN-Only",
          "portRange": "8080-8089",
          "sourceAddressPrefixes": ["10.0.0.0/8", "172.16.0.0/12"],
          "priority": 1020
        }
      ],
      "metadata": { "description": "NSG inbound port rules" }
    },
    "serviceUser": {
      "value": "appuser",
      "metadata": { "description": "Linux user for running the service" }
    },
    "servicePorts": {
      "value": "443, 8080-8089",
      "metadata": { "description": "Ports shown in deployment output" }
    }
  }
}
```

### Inbound Port Rules

Each rule in `inboundPorts` creates an NSG (Network Security Group) rule:

| Field | Description | Example |
|-------|-------------|---------|
| `name` | Rule name (must be unique) | `"Web-Traffic"` |
| `portRange` | Single port or range | `"443"` or `"6000-6007"` |
| `sourceAddressPrefixes` | Array of allowed CIDRs | `["*"]` or `["10.0.0.0/8"]` |
| `priority` | Rule priority (1010+, lower = higher priority) | `1010` |

### Example: Web Application

```json
{
  "parameters": {
    "projectName": { "value": "webapp" },
    "inboundPorts": {
      "value": [
        { "name": "HTTPS", "portRange": "443", "sourceAddressPrefixes": ["*"], "priority": 1010 }
      ]
    },
    "serviceUser": { "value": "www-data" },
    "servicePorts": { "value": "443" }
  }
}
```

## Custom Templates

The deploy script supports custom templates for reuse across projects:

```bash
./deploy.sh \
    -g my-project \
    -n my-vm \
    -e alerts@example.com \
    --bicep ./my-custom.bicep \
    --cloud-init ./my-cloud-init.yaml \
    --parameters ./my-parameters.json \
    --role-definition ./my-role.json
```

This allows you to:
- Use different Bicep templates for different VM configurations
- Customize cloud-init for application-specific setup
- Configure ports and network rules via parameters file
- Define custom RBAC roles with specific permissions

## Troubleshooting

### Cannot Login with Admin Password

The deployment script may fail to set the local admin password correctly. If you cannot log in via Serial Console with the password you entered during deployment:

```bash
az vm user update \
    --resource-group <resource-group> \
    --name <vm-name> \
    --username <admin-username> \
    --password 'YourNewPassword123!'
```

This uses the Azure VM Access extension to reset the password. The command takes 1-2 minutes to complete.
