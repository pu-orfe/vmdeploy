#!/bin/bash
set -euo pipefail

# Post-deployment script for VM configuration
# Use this to reset admin password or complete Entra ID role assignments

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RESOURCE_GROUP=""
VM_NAME=""
RESET_PASSWORD=false
ADMIN_USERNAME=""
ASSIGN_ROLES=false
SERVICE_ADMINS=()
SERVICE_USER="appuser"
PARAMETERS_FILE=""
SSH_USERS=()
CONFIGURE_SSH=false

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Required:
  -g, --resource-group NAME    Azure resource group name
  -n, --name NAME              VM name

Actions:
  --reset-password             Reset the admin password for Serial Console access
  -u, --admin-user USERNAME    Admin username (required with --reset-password)
  --assign-roles               Assign Entra ID roles and sudoers for service admins
  --service-admin EMAIL        Entra ID user for role assignment (repeatable)
  --service-user USERNAME      Service user for sudoers (default: appuser)
  --parameters FILE            Load service user from parameters file
  --ssh-user EMAIL             Restrict SSH access to specific Entra ID user (repeatable)
                               Configures AllowUsers in sshd_config

Examples:
  Reset admin password:
    $0 -g myapp-rg -n myapp-vm --reset-password -u myadmin

  Assign Entra ID roles:
    $0 -g myapp-rg -n myapp-vm --assign-roles \\
       --service-admin user1@example.com \\
       --service-admin user2@example.com

  Configure SSH access for specific users:
    $0 -g myapp-rg -n myapp-vm \\
       --ssh-user user1@example.com \\
       --ssh-user user2@example.com

  All options:
    $0 -g myapp-rg -n myapp-vm --reset-password -u myadmin \\
       --assign-roles --service-admin user@example.com \\
       --ssh-user user@example.com

EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -g|--resource-group)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        -n|--name)
            VM_NAME="$2"
            shift 2
            ;;
        --reset-password)
            RESET_PASSWORD=true
            shift
            ;;
        -u|--admin-user)
            ADMIN_USERNAME="$2"
            shift 2
            ;;
        --assign-roles)
            ASSIGN_ROLES=true
            shift
            ;;
        --service-admin)
            SERVICE_ADMINS+=("$2")
            shift 2
            ;;
        --service-user)
            SERVICE_USER="$2"
            shift 2
            ;;
        --parameters)
            PARAMETERS_FILE="$2"
            shift 2
            ;;
        --ssh-user)
            SSH_USERS+=("$2")
            CONFIGURE_SSH=true
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required arguments
if [[ -z "$RESOURCE_GROUP" ]]; then
    echo "Error: Resource group is required"
    usage
fi

if [[ -z "$VM_NAME" ]]; then
    echo "Error: VM name is required"
    usage
fi

if [[ "$RESET_PASSWORD" == "false" && "$ASSIGN_ROLES" == "false" && "$CONFIGURE_SSH" == "false" ]]; then
    echo "Error: Must specify --reset-password, --assign-roles, and/or --ssh-user"
    usage
fi

if [[ "$RESET_PASSWORD" == "true" && -z "$ADMIN_USERNAME" ]]; then
    echo "Error: --admin-user is required with --reset-password"
    usage
fi

if [[ "$ASSIGN_ROLES" == "true" && ${#SERVICE_ADMINS[@]} -eq 0 ]]; then
    echo "Error: --service-admin is required with --assign-roles"
    usage
fi

# Load service user from parameters file if specified
if [[ -n "$PARAMETERS_FILE" ]]; then
    if [[ ! -f "$PARAMETERS_FILE" ]]; then
        echo "Error: Parameters file not found: $PARAMETERS_FILE"
        exit 1
    fi
    SERVICE_USER=$(jq -r '.parameters.serviceUser.value // "appuser"' "$PARAMETERS_FILE")
    echo "Loaded service user from parameters: $SERVICE_USER"
fi

# Check Azure login
if ! az account show &> /dev/null; then
    echo "Not logged in to Azure. Running 'az login'..."
    az login
fi

# Verify VM exists
if ! az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" &> /dev/null; then
    echo "Error: VM '$VM_NAME' not found in resource group '$RESOURCE_GROUP'"
    exit 1
fi

echo "========================================"
echo "Post-Deployment Configuration"
echo "========================================"
echo "Resource Group: $RESOURCE_GROUP"
echo "VM Name: $VM_NAME"
if [[ "$RESET_PASSWORD" == "true" ]]; then
    echo "Action: Reset password for $ADMIN_USERNAME"
fi
if [[ "$ASSIGN_ROLES" == "true" ]]; then
    echo "Action: Assign Entra ID roles"
    for user in "${SERVICE_ADMINS[@]}"; do
        echo "  - $user"
    done
fi
if [[ "$CONFIGURE_SSH" == "true" ]]; then
    echo "Action: Configure SSH access"
    for user in "${SSH_USERS[@]}"; do
        echo "  - $user"
    done
fi
echo "========================================"
echo ""

# Reset password
if [[ "$RESET_PASSWORD" == "true" ]]; then
    echo "Resetting password for $ADMIN_USERNAME..."
    echo "(min 12 chars, must include uppercase, lowercase, number, and special char)"
    while true; do
        read -s -p "New password: " NEW_PASSWORD
        echo
        read -s -p "Confirm password: " CONFIRM_PASSWORD
        echo
        if [[ "$NEW_PASSWORD" != "$CONFIRM_PASSWORD" ]]; then
            echo "Passwords do not match. Please try again."
            continue
        fi
        if [[ ${#NEW_PASSWORD} -lt 12 ]]; then
            echo "Password must be at least 12 characters. Please try again."
            continue
        fi
        break
    done

    echo ""
    echo "Applying password reset via VMAccessForLinux extension..."
    az vm user update \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --username "$ADMIN_USERNAME" \
        --password "$NEW_PASSWORD" \
        --output none

    echo "Password reset complete for $ADMIN_USERNAME"
    echo ""
fi

# Assign Entra ID roles
if [[ "$ASSIGN_ROLES" == "true" ]]; then
    echo "Configuring Entra ID access..."

    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    VM_RESOURCE_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Compute/virtualMachines/$VM_NAME"

    # Get storage account
    STORAGE_ACCOUNT_NAME=$(az storage account list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || echo "")
    STORAGE_ACCOUNT_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME"

    # Helper function to resolve user email to object ID
    resolve_user_object_id() {
        local email="$1"
        local cmd_output
        if ! cmd_output=$(az ad user show --id "$email" --query id -o tsv 2>&1); then
            if echo "$cmd_output" | grep -q "InteractionRequired\|InvalidAuthenticationToken"; then
                echo ""
                echo "ERROR: Azure CLI token has expired or requires re-authentication."
                echo ""
                echo "Please run:"
                echo "  az account clear && az login"
                echo ""
                echo "Then re-run this script."
                exit 1
            fi
            echo "Error: Could not find user $email" >&2
            return 1
        fi
        echo "$cmd_output"
    }

    # Check if custom role exists, create if not
    CUSTOM_ROLE_NAME="Serial Console User - $VM_NAME"
    if ! az role definition list --name "$CUSTOM_ROLE_NAME" --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
        echo "  Creating custom role '$CUSTOM_ROLE_NAME'..."
        az role definition create --role-definition "{
            \"Name\": \"$CUSTOM_ROLE_NAME\",
            \"Description\": \"Minimum permissions for Serial Console access with Entra ID login to $VM_NAME only\",
            \"Actions\": [
                \"Microsoft.Compute/virtualMachines/read\",
                \"Microsoft.Compute/virtualMachines/retrieveBootDiagnosticsData/action\",
                \"Microsoft.Storage/storageAccounts/read\",
                \"Microsoft.SerialConsole/serialPorts/connect/action\",
                \"Microsoft.Resources/subscriptions/resourceGroups/read\"
            ],
            \"DataActions\": [
                \"Microsoft.Compute/virtualMachines/login/action\"
            ],
            \"AssignableScopes\": [
                \"$VM_RESOURCE_ID\",
                \"$STORAGE_ACCOUNT_ID\"
            ]
        }" --output none 2>/dev/null || echo "    (role may already exist)"

        echo "  Waiting for role to propagate..."
        for i in {1..12}; do
            if az role definition list --name "$CUSTOM_ROLE_NAME" --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
                echo "  Role is now available."
                break
            fi
            if [[ $i -eq 12 ]]; then
                echo "  Warning: Role propagation timeout, continuing anyway..."
            fi
            sleep 5
        done
    fi

    for user in "${SERVICE_ADMINS[@]}"; do
        echo "  Granting access to $user..."

        # Resolve user to object ID
        object_id=$(resolve_user_object_id "$user") || continue

        # Virtual Machine User Login
        az role assignment create \
            --assignee-object-id "$object_id" \
            --assignee-principal-type User \
            --role "Virtual Machine User Login" \
            --scope "$VM_RESOURCE_ID" \
            --output none 2>/dev/null || echo "    (VM User Login role may already be assigned)"

        # Custom Serial Console role on VM
        az role assignment create \
            --assignee-object-id "$object_id" \
            --assignee-principal-type User \
            --role "$CUSTOM_ROLE_NAME" \
            --scope "$VM_RESOURCE_ID" \
            --output none 2>/dev/null || echo "    (VM custom role may already be assigned)"

        # Custom Serial Console role on storage
        if [[ -n "$STORAGE_ACCOUNT_NAME" ]]; then
            az role assignment create \
                --assignee-object-id "$object_id" \
                --assignee-principal-type User \
                --role "$CUSTOM_ROLE_NAME" \
                --scope "$STORAGE_ACCOUNT_ID" \
                --output none 2>/dev/null || echo "    (Storage role may already be assigned)"
        fi

        echo "    Done: $user"
    done

    echo ""
    echo "Entra ID role assignments complete."

    # Configure sudoers on the VM for service admins
    echo "Configuring sudoers for service admins on VM..."

    # Build sudoers content - uses machinectl for proper dbus session
    SUDOERS_CONTENT="# Service admin users can act as the service user\\n"
    SUDOERS_CONTENT+="# Entra ID users use email as username\\n"
    SUDOERS_CONTENT+="# Uses machinectl for proper dbus session\\n"
    SUDOERS_CONTENT+="# Generated by post-deploy.sh\\n"
    for user in "${SERVICE_ADMINS[@]}"; do
        SUDOERS_CONTENT+="$user ALL=(root) NOPASSWD: /bin/machinectl shell ${SERVICE_USER}@\\n"
        SUDOERS_CONTENT+="$user ALL=(root) NOPASSWD: /bin/systemctl start ${SERVICE_USER}*, /bin/systemctl stop ${SERVICE_USER}*, /bin/systemctl restart ${SERVICE_USER}*, /bin/systemctl status ${SERVICE_USER}*\\n"
    done

    # Apply via Run Command
    az vm run-command invoke \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --command-id RunShellScript \
        --scripts "echo -e '$SUDOERS_CONTENT' > /etc/sudoers.d/service-admins && chmod 440 /etc/sudoers.d/service-admins" \
        --output none 2>/dev/null || echo "  Warning: Could not configure sudoers via Run Command"

    echo "  Sudoers configured for service user: $SERVICE_USER"
    echo ""
fi

# Configure SSH user restrictions
if [[ "$CONFIGURE_SSH" == "true" ]]; then
    echo "Configuring SSH access restrictions..."

    # Build AllowUsers directive (Entra ID users only)
    ALLOW_USERS=""
    for user in "${SSH_USERS[@]}"; do
        if [[ -z "$ALLOW_USERS" ]]; then
            ALLOW_USERS="$user"
        else
            ALLOW_USERS="$ALLOW_USERS $user"
        fi
    done

    # Apply SSH configuration via Run Command
    az vm run-command invoke \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --command-id RunShellScript \
        --scripts "
# Get existing AllowUsers if any
EXISTING=\$(grep '^AllowUsers' /etc/ssh/sshd_config 2>/dev/null | sed 's/^AllowUsers //' || echo '')

# Merge with new users, remove duplicates
ALL_USERS=\"\$EXISTING $ALLOW_USERS\"
UNIQUE_USERS=\$(echo \"\$ALL_USERS\" | tr ' ' '\n' | sort -u | tr '\n' ' ' | xargs)

# Remove any existing AllowUsers directive
sed -i '/^AllowUsers/d' /etc/ssh/sshd_config

# Add AllowUsers directive with unique users
echo \"AllowUsers \$UNIQUE_USERS\" >> /etc/ssh/sshd_config

# Restart sshd
systemctl restart sshd

echo \"SSH access restricted to: \$UNIQUE_USERS\"
" \
        --output none 2>/dev/null || echo "  Warning: Could not configure SSH restrictions via Run Command"

    echo "  SSH access restricted to: $ALLOW_USERS"
    echo ""
fi

echo "========================================"
echo "Post-Deployment Complete"
echo "========================================"
echo ""
echo "Serial Console access:"
echo "  az serial-console connect -n $VM_NAME -g $RESOURCE_GROUP"
echo ""
if [[ "$RESET_PASSWORD" == "true" ]]; then
    echo "Local admin login:"
    echo "  Username: $ADMIN_USERNAME"
    echo "  Password: (as entered above)"
    echo ""
fi
if [[ "$ASSIGN_ROLES" == "true" ]]; then
    echo "Entra ID login (at Serial Console prompt):"
    for user in "${SERVICE_ADMINS[@]}"; do
        echo "  - $user"
    done
    echo ""
fi
if [[ "$CONFIGURE_SSH" == "true" ]]; then
    echo "SSH access allowed for:"
    for user in "${SSH_USERS[@]}"; do
        echo "  - $user"
    done
    echo ""
fi
