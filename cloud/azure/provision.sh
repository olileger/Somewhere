#!/bin/bash
set -euo pipefail

# =============================================================================
# Azure Spot VM Provisioning for Alpine WireGuard VPN
# =============================================================================
# This script provisions a minimal Spot VM on Azure with Alpine Linux
# and configures it as a WireGuard VPN server.
#
# Requirements:
#   - Azure CLI installed and logged in (az login)
#   - jq for JSON parsing (install with: sudo apt install jq / brew install jq)
#
# Usage: ./provision.sh
# =============================================================================

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
LOCATION="francecentral"  # Change to your preferred region
VM_SIZE="Standard_B1ls"  # ARM-based, cheapest option (512MB RAM, 1 vCPU)
# Alternative x86 options: Standard_B1s (1 vCPU, 1GB RAM)
DISK_SIZE_GB="32"  # S4 = 32 GiB Standard HDD
DISK_TYPE="Standard_LRS"  # Managed Standard HDD (valid az vm create storage SKU)
RESOURCE_GROUP_NAME="vpn-rg-${USER}"
VM_NAME="wireguard-vpn-alpine"
NETWORK_NAME="vpn-vnet"
SUBNET_NAME="vpn-subnet"
PUBLIC_IP_NAME="vpn-public-ip"
NETWORK_SECURITY_GROUP_NAME="vpn-nsg"
ADMIN_USER=""

# WireGuard port
WG_PORT="51820"

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

echo_info() {
    echo "[Azure INFO] $1"
}

echo_error() {
    echo "[Azure ERROR] $1" >&2
    exit 1
}

# Check if Azure CLI is installed
check_azure_cli() {
    if ! command -v az &> /dev/null; then
        echo_error "Azure CLI is not installed. Please install it first."
        echo_error "See: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    fi
}

# Check if logged in
check_azure_login() {
    if ! az account show &> /dev/null; then
        echo_error "Not logged in to Azure. Please run 'az login' first."
    fi
}

# Check if jq is installed
check_jq() {
    if ! command -v jq &> /dev/null; then
        echo_error "jq is not installed. Please install it (sudo apt install jq / brew install jq)."
    fi
}

generate_admin_user() {
    ADMIN_USER=$(LC_ALL=C tr -dc 'a-z' </dev/urandom | head -c 12 || true)
    if [ "${#ADMIN_USER}" -ne 12 ]; then
        echo_error "Failed to generate admin username."
    fi
}

# -----------------------------------------------------------------------------
# Get credentials
# -----------------------------------------------------------------------------

echo "======================================================================"
echo "Azure Spot VM Provisioning for WireGuard VPN"
echo "======================================================================"

generate_admin_user

while true; do
    read -r -s -p "Enter admin/sudo password for the VM: " ADMIN_PASSWORD
    echo
    if [ -n "$ADMIN_PASSWORD" ]; then
        break
    fi
    echo_error "Password cannot be empty."
done

while true; do
    read -r -s -p "Confirm admin/sudo password: " ADMIN_PASSWORD_CONFIRM
    echo
    if [ -n "$ADMIN_PASSWORD_CONFIRM" ]; then
        if [ "$ADMIN_PASSWORD" = "$ADMIN_PASSWORD_CONFIRM" ]; then
            break
        else
            echo_error "Passwords do not match."
        fi
    fi
    echo_error "Password cannot be empty."
done

# -----------------------------------------------------------------------------
# Initialize
# -----------------------------------------------------------------------------

check_azure_cli
check_azure_login
check_jq

# Set default location
export AZURE_LOCATION="$LOCATION"

# -----------------------------------------------------------------------------
# Step 1: Create resource group
# -----------------------------------------------------------------------------

echo_info "Creating resource group..."
if ! az group show --name "$RESOURCE_GROUP_NAME" --location "$LOCATION" &> /dev/null; then
    az group create --name "$RESOURCE_GROUP_NAME" --location "$LOCATION"
    echo_info "Resource group created: $RESOURCE_GROUP_NAME"
else
    echo_info "Using existing resource group: $RESOURCE_GROUP_NAME"
fi

# -----------------------------------------------------------------------------
# Step 2: Create virtual network and subnet
# -----------------------------------------------------------------------------

echo_info "Creating virtual network and subnet..."
if ! az network vnet show --name "$NETWORK_NAME" --resource-group "$RESOURCE_GROUP_NAME" &> /dev/null; then
    az network vnet create \
        --name "$NETWORK_NAME" \
        --resource-group "$RESOURCE_GROUP_NAME" \
        --location "$LOCATION" \
        --address-prefixes "10.0.0.0/16" \
        --subnet-name "$SUBNET_NAME" \
        --subnet-prefixes "10.0.0.0/24"
    echo_info "Virtual network created: $NETWORK_NAME"
else
    echo_info "Using existing virtual network: $NETWORK_NAME"
fi

# Get subnet ID
SUBNET_ID=$(az network vnet subnet show \
    --name "$SUBNET_NAME" \
    --vnet-name "$NETWORK_NAME" \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --query id \
    --output tsv)

# -----------------------------------------------------------------------------
# Step 3: Create public IP (static)
# -----------------------------------------------------------------------------

echo_info "Creating public IP..."
PUBLIC_IP_ID=$(az network public-ip create \
    --name "$PUBLIC_IP_NAME" \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --location "$LOCATION" \
    --allocation-method Static \
    --query id \
    --output tsv)

PUBLIC_IP=$(az network public-ip show \
    --name "$PUBLIC_IP_NAME" \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --query ipAddress \
    --output tsv)

echo_info "Public IP allocated: $PUBLIC_IP"

# -----------------------------------------------------------------------------
# Step 4: Create network security group (only WireGuard port open)
# -----------------------------------------------------------------------------

echo_info "Creating network security group..."
NSG_ID=$(az network nsg create \
    --name "$NETWORK_SECURITY_GROUP_NAME" \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --location "$LOCATION" \
    --query id \
    --output tsv)

# Add rule for WireGuard (UDP)
az network nsg rule create \
    --name "AllowWireGuard" \
    --nsg-name "$NETWORK_SECURITY_GROUP_NAME" \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --protocol Udp \
    --direction Inbound \
    --priority 100 \
    --source-address-prefixes "*" \
    --source-port-ranges "*" \
    --destination-address-prefixes "*" \
    --destination-port-ranges "$WG_PORT" \
    --access Allow

# Add rule for ICMP (ping)
az network nsg rule create \
    --name "AllowICMP" \
    --nsg-name "$NETWORK_SECURITY_GROUP_NAME" \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --protocol Icmp \
    --direction Inbound \
    --priority 200 \
    --source-address-prefixes "*" \
    --access Allow

echo_info "Network security group configured (only UDP/${WG_PORT} and ICMP)."

# -----------------------------------------------------------------------------
# Step 5: Create network interface
# -----------------------------------------------------------------------------

echo_info "Creating network interface..."
NIC_ID=$(az network nic create \
    --name "${VM_NAME}-nic" \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --location "$LOCATION" \
    --vnet-name "$NETWORK_NAME" \
    --subnet "$SUBNET_NAME" \
    --public-ip-address "$PUBLIC_IP_NAME" \
    --network-security-group "$NETWORK_SECURITY_GROUP_NAME" \
    --query id \
    --output tsv)

echo_info "Network interface created."

# -----------------------------------------------------------------------------
# Step 6: Encode setup script and credentials for user data
# -----------------------------------------------------------------------------

echo_info "Preparing cloud-init configuration..."

# Read the setup script
SETUP_SCRIPT_PATH="../../../os/alpine/setup-vpn.sh"
if [ ! -f "$SETUP_SCRIPT_PATH" ]; then
    echo_error "Setup script not found at: $SETUP_SCRIPT_PATH"
fi

# Encode the setup script to base64
SETUP_SCRIPT_BASE64=$(base64 -w0 "$SETUP_SCRIPT_PATH" 2>/dev/null || base64 "$SETUP_SCRIPT_PATH" | tr -d '\n')

# Encode credentials to base64
ADMIN_PASSWORD_B64=$(echo -n "$ADMIN_PASSWORD" | base64 -w0 2>/dev/null || echo -n "$ADMIN_PASSWORD" | base64 | tr -d '\n')
# -----------------------------------------------------------------------------
# Step 7: Create the VM (Spot)
# -----------------------------------------------------------------------------

echo_info "Launching Spot VM..."

# Find Alpine Linux image
ALPINE_IMAGE=$(az vm image list \
    --location "$LOCATION" \
    --publisher "alpine" \
    --offer "alpine" \
    --sku "3-18" \
    --query "[0].urn" \
    --output tsv 2>/dev/null)

if [ -z "$ALPINE_IMAGE" ]; then
    # Try without specific version
    ALPINE_IMAGE=$(az vm image list \
        --location "$LOCATION" \
        --publisher "alpine" \
        --offer "alpine" \
        --query "[0].urn" \
        --output tsv 2>/dev/null)
fi

if [ -z "$ALPINE_IMAGE" ]; then
    echo_error "Could not find Alpine Linux image in region $LOCATION."
    echo_error "Try a different location or check available images with:"
    echo_error "  az vm image list --location $LOCATION --publisher alpine"
fi

echo_info "Using Alpine image: $ALPINE_IMAGE"

# Create cloud-init configuration
CLOUD_INIT_CONFIG=$(cat <<EOF
#cloud-config
package_update: true
packages:
  - coreutils
  - curl
runcmd:
  - |
    # Decode and run setup script
    echo "$SETUP_SCRIPT_BASE64" | base64 -d > /tmp/setup-vpn.sh
    chmod +x /tmp/setup-vpn.sh
    # Set credentials as environment variables
    export ADMIN_USER="$ADMIN_USER"
    export ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d)
    # Run setup
    /tmp/setup-vpn.sh
    rm /tmp/setup-vpn.sh
    # Signal completion
    touch /tmp/vpn-setup-complete
final_message: "WireGuard VPN setup complete!"
EOF
)

# Create VM with Spot priority
VM_ID=$(az vm create \
    --name "$VM_NAME" \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --location "$LOCATION" \
    --image "$ALPINE_IMAGE" \
    --size "$VM_SIZE" \
    --admin-username "$ADMIN_USER" \
    --admin-password "$ADMIN_PASSWORD" \
    --priority Spot \
    --eviction-policy Deallocate \
    --nics "${VM_NAME}-nic" \
    --storage-sku "$DISK_TYPE" \
    --os-disk-size-gb "$DISK_SIZE_GB" \
    --custom-data "$CLOUD_INIT_CONFIG" \
    --query id \
    --output tsv)

echo_info "VM created: $VM_ID"

# -----------------------------------------------------------------------------
# Step 8: Wait for VM to be running
# -----------------------------------------------------------------------------

echo_info "Waiting for VM to be running..."
az vm wait --name "$VM_NAME" --resource-group "$RESOURCE_GROUP_NAME" --created --timeout 300

echo_info "Waiting for VPN setup to complete (this may take 2-3 minutes)..."
sleep 60

# -----------------------------------------------------------------------------
# Step 9: Display summary
# -----------------------------------------------------------------------------

echo ""
echo "======================================================================"
echo "Azure Spot VM Provisioning Complete!"
echo "======================================================================"
echo ""
echo "VM Details:"
echo "  VM Name: $VM_NAME"
echo "  Public IP: $PUBLIC_IP"
echo "  Location: $LOCATION"
echo "  VM Size: $VM_SIZE (Spot)"
echo "  Resource Group: $RESOURCE_GROUP_NAME"
echo ""
echo "Credentials (save these!):"
echo "  Admin Username: $ADMIN_USER"
echo "  Admin Password: [the password you entered]"
echo ""
echo "WireGuard Configuration:"
echo "  Port: ${WG_PORT}/udp"
echo "  Endpoint: ${PUBLIC_IP}:${WG_PORT}"
echo ""
echo "Client Configuration:"
echo "  The client config file is generated on the server at:"
echo "    /etc/wireguard/clients/client.conf"
echo "    /etc/wireguard/clients/client_privatekey"
echo "    /etc/wireguard/clients/client_publickey"
echo ""
echo "  To retrieve the client config file:"
echo "    1. Temporarily enable SSH in the NSG:"
echo "       az network nsg rule create \\"
echo "         --name AllowSSH \\"
echo "         --nsg-name $NETWORK_SECURITY_GROUP_NAME \\"
echo "         --resource-group $RESOURCE_GROUP_NAME \\"
echo "         --protocol Tcp --direction Inbound \\"
echo "         --priority 300 --source-address-prefixes YOUR_IP \\"
echo "         --destination-port-ranges 22 --access Allow"
echo "    2. SSH to the instance: ssh ${ADMIN_USER}@${PUBLIC_IP}"
echo "    3. Get the config: cat /etc/wireguard/clients/client.conf"
echo "    4. Remove SSH access:"
echo "       az network nsg rule delete \\"
echo "         --name AllowSSH \\"
echo "         --nsg-name $NETWORK_SECURITY_GROUP_NAME \\"
echo "         --resource-group $RESOURCE_GROUP_NAME"
echo ""
echo "Alternatively, use the Azure Serial Console:"
echo "  az serial-console connect --name $VM_NAME --resource-group $RESOURCE_GROUP_NAME"
echo ""
echo "Cost Estimate:"
echo "  VM (Spot B1ls): ~\$0.0003-\$0.001/hour (varies by region)"
echo "  Disk (32GB Standard_LRS): ~\$1/month"
echo "  Public IP: Free (while attached to running VM)"
echo ""
echo "To terminate the VM:"
echo "  az vm deallocate --name $VM_NAME --resource-group $RESOURCE_GROUP_NAME"
echo "  az vm delete --name $VM_NAME --resource-group $RESOURCE_GROUP_NAME --yes"
echo "  az group delete --name $RESOURCE_GROUP_NAME --yes --no-wait"
echo ""
echo "Note: Spot VMs may be evicted at any time by Azure."
echo "======================================================================"
