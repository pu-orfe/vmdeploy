#!/bin/bash
set -euo pipefail

# Azure VM Data Download Script
# Transfers files FROM Azure VM to local machine via temporary Blob Storage container
# Automatically cleans up the container after transfer to avoid ongoing costs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
RESOURCE_GROUP=""
VM_NAME=""
DRY_RUN=false
VERBOSE=false

# Transfer paths (can specify multiple)
declare -a VM_PATHS=()
declare -a LOCAL_PATHS=()

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Transfer files FROM Azure VM to local machine via temporary Blob Storage.
The storage container is automatically deleted after transfer to avoid costs.

Required:
  -g, --resource-group NAME    Azure resource group (must match deployment)
  -n, --name NAME              VM name (must match deployment)

Transfer Paths (at least one required):
  -t, --transfer VM:LOCAL      Transfer VM path to LOCAL path
                               Can be specified multiple times
                               Directories are transferred recursively

Options:
  --dry-run                    Show what would happen without transferring
  -v, --verbose                Show detailed progress
  -h, --help                   Show this help message

Examples:
  # Transfer single directory from VM to local
  $0 -g hfm-rg -n hfm-vm -t /home/hfm/data:./hfm-data

  # Dry run to preview
  $0 -g hfm-rg -n hfm-vm -t /home/hfm/data:./hfm-data --dry-run

Prerequisites:
  - Azure CLI (az) installed and logged in
  - azcopy installed locally (for downloading)
  - azcopy installed on VM (included in cloud-init)
  - VM deployed via deploy.sh with boot diagnostics storage account
EOF
    exit 1
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        log "$*"
    fi
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
        -t|--transfer)
            TRANSFER_SPEC="$2"
            if [[ ! "$TRANSFER_SPEC" =~ : ]]; then
                echo "Error: Transfer path must be in VM:LOCAL format"
                exit 1
            fi
            VM_PATH="${TRANSFER_SPEC%%:*}"
            LOCAL_PATH="${TRANSFER_SPEC#*:}"
            VM_PATHS+=("$VM_PATH")
            LOCAL_PATHS+=("$LOCAL_PATH")
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
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

if [[ ${#VM_PATHS[@]} -eq 0 ]]; then
    echo "Error: At least one transfer path is required"
    usage
fi

# Check for required tools
if ! command -v az &> /dev/null; then echo "Error: az not installed"; exit 1; fi
if ! command -v azcopy &> /dev/null; then echo "Error: azcopy not installed"; exit 1; fi

# Get storage account
STORAGE_ACCOUNT=$(az storage account list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null)
if [[ -z "$STORAGE_ACCOUNT" ]]; then
    echo "Error: No storage account found in $RESOURCE_GROUP"
    exit 1
fi

CONTAINER_NAME="download-$(date +%Y%m%d-%H%M%S)-$$"

echo ""
echo "========================================"
echo "Data Download from Azure VM"
echo "========================================"
echo "Resource Group: $RESOURCE_GROUP"
echo "VM Name: $VM_NAME"
echo "Storage Account: $STORAGE_ACCOUNT"
echo "Container: $CONTAINER_NAME (temporary)"
echo ""
echo "Transfers:"
for i in "${!VM_PATHS[@]}"; do
    echo "  VM:${VM_PATHS[$i]} -> LOCAL:${LOCAL_PATHS[$i]}"
done
echo "========================================"

if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "DRY RUN: No files will be transferred."
    exit 0
fi

# Cleanup
cleanup() {
    if [[ -n "${CONTAINER_CREATED:-}" ]]; then
        log "Cleaning up: Deleting container '$CONTAINER_NAME'..."
        az storage container delete --name "$CONTAINER_NAME" --account-name "$STORAGE_ACCOUNT" --auth-mode login --output none 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Step 1: Create container
log "Step 1: Creating temporary container..."
az storage container create --name "$CONTAINER_NAME" --account-name "$STORAGE_ACCOUNT" --auth-mode login --output none
CONTAINER_CREATED=true

# Step 2: Generate SAS
SAS_EXPIRY=$(date -u -v+1H '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -d '+1 hour' '+%Y-%m-%dT%H:%MZ')
SAS_TOKEN=$(az storage container generate-sas --name "$CONTAINER_NAME" --account-name "$STORAGE_ACCOUNT" --as-user --auth-mode login --permissions rwdl --expiry "$SAS_EXPIRY" -o tsv 2>/dev/null)

BLOB_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER_NAME}"

# Step 3: Upload from VM to Blob
log "Step 2: Uploading from VM to Blob storage..."
UPLOAD_SCRIPT="#!/bin/bash
set -e
"
for i in "${!VM_PATHS[@]}"; do
    VM_PATH="${VM_PATHS[$i]}"
    UPLOAD_SCRIPT+="
echo 'Uploading: $VM_PATH'
azcopy copy '$VM_PATH' '${BLOB_URL}/transfer-${i}?${SAS_TOKEN}' --recursive 2>&1 || echo 'Warning: Some files may have failed to upload'
"
done

az vm run-command invoke --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --command-id RunShellScript --scripts "$UPLOAD_SCRIPT" --output none

# Step 4: Download from Blob to Local
log "Step 3: Downloading from Blob storage to local machine..."
for i in "${!LOCAL_PATHS[@]}"; do
    LOCAL_PATH="${LOCAL_PATHS[$i]}"
    mkdir -p "$(dirname "$LOCAL_PATH")"
    azcopy copy "${BLOB_URL}/transfer-${i}/*?${SAS_TOKEN}" "$LOCAL_PATH" --recursive
done

log "Download complete!"
