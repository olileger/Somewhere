#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SETUP_SCRIPT="${REPO_ROOT}/os/ubuntu/setup-vpn.sh"
VPN_CONF_FILE="${VPN_CONF_FILE:-${REPO_ROOT}/vpn.conf}"
if [ -f "$VPN_CONF_FILE" ]; then
    . "$VPN_CONF_FILE"
fi

LOCATION="${LOCATION:-}"
LOCATION_DISPLAY_NAME="${LOCATION_DISPLAY_NAME:-}"
RESOURCE_GROUP_NAME="${RESOURCE_GROUP_NAME:-somewhere}"
VM_SIZE="${VM_SIZE:-Standard_B1ls}"
DISK_SIZE_GB="${DISK_SIZE_GB:-32}"
DISK_TYPE="${DISK_TYPE:-Standard_LRS}"
VM_NAME="${VM_NAME:-wireguard-vpn-ubuntu-minimal}"
NETWORK_NAME="${NETWORK_NAME:-vpn-vnet}"
SUBNET_NAME="${SUBNET_NAME:-vpn-subnet}"
PUBLIC_IP_NAME="${PUBLIC_IP_NAME:-vpn-public-ip}"
NETWORK_SECURITY_GROUP_NAME="${NETWORK_SECURITY_GROUP_NAME:-vpn-nsg}"
WG_PORT="${WG_PORT:-51820}"
WG_CLIENT_ADDRESS="${WG_CLIENT_ADDRESS:-10.8.0.2/24}"
WG_CLIENT_DNS="${WG_CLIENT_DNS:-8.8.8.8, 8.8.4.4}"
WG_CLIENT_ALLOWED_IPS="${WG_CLIENT_ALLOWED_IPS:-0.0.0.0/0, ::/0}"
WG_CLIENT_KEEPALIVE="${WG_CLIENT_KEEPALIVE:-25}"
ADMIN_USER="${ADMIN_USER:-}"
VM_IMAGE="${VM_IMAGE:-Ubuntu2404}"
AUTO_SHUTDOWN_TIME="${AUTO_SHUTDOWN_TIME:-2330}"
bootstrap_script=""

echo_info() {
    echo "[Azure INFO] $1"
}

echo_warning() {
    echo "[Azure WARN] $1" >&2
}

echo_error() {
    echo "[Azure ERROR] $1" >&2
    exit 1
}

check_azure_cli() {
    if ! command -v az &> /dev/null; then
        echo_error "Azure CLI is not installed. Please install it first."
    fi
}

check_keygen_tools() {
    if ! command -v openssl &> /dev/null; then
        echo_error "openssl is required to generate the client key pair. Please install it first."
    fi
}

# Generate a WireGuard-compatible X25519 key pair locally using openssl only.
# The client private key never leaves this machine; only the public key is sent
# to the server. Produces CLIENT_PRIVATE_KEY and CLIENT_PUBLIC_KEY (base64).
generate_client_keypair() {
    local priv_file
    priv_file="$(mktemp)"

    # Derive both keys from the same private key so no DER header is hardcoded;
    # the trailing 32 bytes of the DER encoding are the raw key material.
    openssl genpkey -algorithm X25519 -out "$priv_file"
    CLIENT_PRIVATE_KEY=$(openssl pkey -in "$priv_file" -outform DER | tail -c 32 | base64)
    CLIENT_PUBLIC_KEY=$(openssl pkey -in "$priv_file" -pubout -outform DER | tail -c 32 | base64)

    rm -f "$priv_file"

    if [ -z "$CLIENT_PRIVATE_KEY" ] || [ -z "$CLIENT_PUBLIC_KEY" ]; then
        echo_error "Failed to generate the client key pair."
    fi
}

check_azure_login() {
    if ! az account show &> /dev/null; then
        echo_error "Not logged in to Azure. Please run 'az login' first."
    fi
}

select_continent() {
    local choice

    while true; do
        echo "Select a continent:"
        echo "  1) North America"
        echo "  2) South America"
        echo "  3) Europe"
        echo "  4) Africa"
        echo "  5) Asia"
        echo "  6) Oceania"
        read -r -p "Continent (1-6): " choice

        case "$choice" in
            1) AZURE_GEOGRAPHY_GROUP="North America"; return 0 ;;
            2) AZURE_GEOGRAPHY_GROUP="South America"; return 0 ;;
            3) AZURE_GEOGRAPHY_GROUP="Europe"; return 0 ;;
            4) AZURE_GEOGRAPHY_GROUP="Africa"; return 0 ;;
            5) AZURE_GEOGRAPHY_GROUP="Asia"; return 0 ;;
            6) AZURE_GEOGRAPHY_GROUP="Oceania"; return 0 ;;
            *) echo_warning "Please choose a number between 1 and 6." ;;
        esac
    done
}

select_location_for_continent() {
    local locations=() choice index display_name region_name

    while IFS= read -r line; do
        locations+=("$line")
    done < <(az account list-locations \
        --query "[?metadata.geographyGroup=='$AZURE_GEOGRAPHY_GROUP'] | sort_by(@, &displayName) | [].{displayName:displayName,name:name}" \
        --output tsv)

    if [ "${#locations[@]}" -eq 0 ]; then
        echo_error "No Azure regions found for continent: $AZURE_GEOGRAPHY_GROUP"
    fi

    echo_info "Available regions in $AZURE_GEOGRAPHY_GROUP:"
    for index in "${!locations[@]}"; do
        IFS=$'\t' read -r display_name region_name <<< "${locations[$index]}"
        echo "  $((index + 1))) $display_name [$region_name]"
    done

    while true; do
        read -r -p "Region number (1-${#locations[@]}): " choice

        case "$choice" in
            ''|*[!0-9]*)
                echo_warning "Please choose a valid number."
                continue
                ;;
        esac

        if [ "$choice" -ge 1 ] && [ "$choice" -le "${#locations[@]}" ]; then
            index=$((choice - 1))
            IFS=$'\t' read -r LOCATION_DISPLAY_NAME LOCATION <<< "${locations[$index]}"
            return 0
        fi

        echo_warning "Please choose a number between 1 and ${#locations[@]}."
    done
}

resolve_location_display_name() {
    LOCATION_DISPLAY_NAME=$(az account list-locations \
        --query "[?name=='$LOCATION'] | [0].displayName" \
        --output tsv)

    if [ -z "$LOCATION_DISPLAY_NAME" ]; then
        LOCATION_DISPLAY_NAME="$LOCATION"
    fi
}

select_location() {
    if [ -n "$LOCATION" ]; then
        resolve_location_display_name
        echo_info "Using preselected Azure region: $LOCATION_DISPLAY_NAME [$LOCATION]"
        return 0
    fi

    select_continent
    select_location_for_continent
}

generate_admin_user() {
    if [ -z "$ADMIN_USER" ]; then
        ADMIN_USER=$(LC_ALL=C tr -dc 'a-z' </dev/urandom | head -c 12 || true)
    fi

    if [ "${#ADMIN_USER}" -ne 12 ] || [[ "$ADMIN_USER" =~ [^a-z] ]]; then
        echo_error "ADMIN_USER must be exactly 12 lowercase letters."
    fi
}

prompt_admin_password() {
    local admin_password_confirm

    while true; do
        echo "The password length must be between 12 and 72. Password must have 3 of the following: 1 lower case character, 1 upper case character, 1 number and 1 special character."
        read -r -s -p "Enter admin/sudo password for the VM: " ADMIN_PASSWORD
        echo
        if [ -n "$ADMIN_PASSWORD" ]; then
            break
        fi
        echo_error "Password cannot be empty."
    done

    while true; do
        read -r -s -p "Confirm admin/sudo password: " admin_password_confirm
        echo
        if [ -n "$admin_password_confirm" ]; then
            if [ "$ADMIN_PASSWORD" = "$admin_password_confirm" ]; then
                break
            fi
            echo_error "Passwords do not match."
        fi
        echo_error "Password cannot be empty."
    done
}

shell_single_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\"'\"'/g")"
}

write_run_command_script() {
    local script_file="$1"
    local server_public_ip="$2"

    {
        printf '#!/bin/bash\n'
        printf 'set -euo pipefail\n'
        printf 'export DEBIAN_FRONTEND=noninteractive\n'
        printf 'export ADMIN_USER=%s\n' "$(shell_single_quote "$ADMIN_USER")"
        printf 'export ADMIN_PASSWORD=%s\n' "$(shell_single_quote "$ADMIN_PASSWORD")"
        printf 'export SERVER_PUBLIC_IP=%s\n' "$(shell_single_quote "$server_public_ip")"
        printf 'export CLIENT_PUBLIC_KEY=%s\n' "$(shell_single_quote "$CLIENT_PUBLIC_KEY")"
        printf '\n'
        printf '# --- shared VPN configuration (vpn.conf) ---\n'
        cat "$VPN_CONF_FILE"
        printf '\n'
        cat "$SETUP_SCRIPT"
    } > "$script_file"
}

main() {
    local public_ip server_public_key client_config_file

    echo "======================================================================"
    echo "Azure CLI Deployment for WireGuard VPN"
    echo "======================================================================"

    check_azure_cli
    check_azure_login
    check_keygen_tools

    if [ ! -f "$SETUP_SCRIPT" ]; then
        echo_error "Setup script not found at: $SETUP_SCRIPT"
    fi

    if [ ! -f "$VPN_CONF_FILE" ]; then
        echo_error "Shared VPN configuration not found at: $VPN_CONF_FILE"
    fi

    select_location
    generate_admin_user
    prompt_admin_password
    generate_client_keypair

    echo_info "Creating resource group..."
    az group create \
        --name "$RESOURCE_GROUP_NAME" \
        --location "$LOCATION" \
        --output none

    echo_info "Creating virtual network and subnet..."
    az network vnet create \
        --resource-group "$RESOURCE_GROUP_NAME" \
        --name "$NETWORK_NAME" \
        --address-prefixes 10.0.0.0/16 \
        --subnet-name "$SUBNET_NAME" \
        --subnet-prefixes 10.0.0.0/24 \
        --output none

    echo_info "Creating public IP..."
    az network public-ip create \
        --resource-group "$RESOURCE_GROUP_NAME" \
        --name "$PUBLIC_IP_NAME" \
        --sku Standard \
        --allocation-method Static \
        --version IPv4 \
        --output none

    echo_info "Creating network security group..."
    az network nsg create \
        --resource-group "$RESOURCE_GROUP_NAME" \
        --name "$NETWORK_SECURITY_GROUP_NAME" \
        --output none

    echo_info "Allowing WireGuard and explicitly denying SSH from the Internet at the NSG"
    az network nsg rule create \
        --resource-group "$RESOURCE_GROUP_NAME" \
        --nsg-name "$NETWORK_SECURITY_GROUP_NAME" \
        --name AllowWireGuard \
        --priority 110 \
        --access Allow \
        --direction Inbound \
        --protocol Udp \
        --source-address-prefixes '*' \
        --source-port-ranges '*' \
        --destination-address-prefixes '*' \
        --destination-port-ranges "$WG_PORT" \
        --output none

    az network nsg rule create \
        --resource-group "$RESOURCE_GROUP_NAME" \
        --nsg-name "$NETWORK_SECURITY_GROUP_NAME" \
        --name DenySSH \
        --priority 120 \
        --access Deny \
        --direction Inbound \
        --protocol Tcp \
        --source-address-prefixes Internet \
        --source-port-ranges '*' \
        --destination-address-prefixes '*' \
        --destination-port-ranges 22 \
        --output none

    echo_info "Creating network interface..."
    az network nic create \
        --resource-group "$RESOURCE_GROUP_NAME" \
        --name "${VM_NAME}-nic" \
        --vnet-name "$NETWORK_NAME" \
        --subnet "$SUBNET_NAME" \
        --network-security-group "$NETWORK_SECURITY_GROUP_NAME" \
        --public-ip-address "$PUBLIC_IP_NAME" \
        --output none

    echo_info "Creating virtual machine..."
    az vm create \
        --resource-group "$RESOURCE_GROUP_NAME" \
        --name "$VM_NAME" \
        --image "$VM_IMAGE" \
        --size "$VM_SIZE" \
        --admin-username "$ADMIN_USER" \
        --admin-password "$ADMIN_PASSWORD" \
        --authentication-type password \
        --nics "${VM_NAME}-nic" \
        --os-disk-size-gb "$DISK_SIZE_GB" \
        --storage-sku "$DISK_TYPE" \
        --output none

    echo_info "Enabling auto-shutdown at 23:30 UTC without notification..."
    az vm auto-shutdown \
        --resource-group "$RESOURCE_GROUP_NAME" \
        --name "$VM_NAME" \
        --time "$AUTO_SHUTDOWN_TIME" \
        --output none

    public_ip=$(az network public-ip show \
        --resource-group "$RESOURCE_GROUP_NAME" \
        --name "$PUBLIC_IP_NAME" \
        --query ipAddress \
        --output tsv)

    bootstrap_script="$(mktemp)"
    trap 'rm -f "${bootstrap_script:-}"' EXIT
    write_run_command_script "$bootstrap_script" "$public_ip"

    echo_info "Running os/ubuntu/setup-vpn.sh through Run Command..."
    az vm run-command invoke \
        --resource-group "$RESOURCE_GROUP_NAME" \
        --name "$VM_NAME" \
        --command-id RunShellScript \
        --scripts @"$bootstrap_script" \
        --query "value[0].message" \
        --output tsv

    echo_info "Retrieving server public key..."
    server_public_key=$(az vm run-command invoke \
        --resource-group "$RESOURCE_GROUP_NAME" \
        --name "$VM_NAME" \
        --command-id RunShellScript \
        --scripts "cat /etc/wireguard/publickey" \
        --query "value[0].message" \
        --output tsv)

    # Run Command wraps stdout/stderr; keep only the base64 key line.
    server_public_key=$(printf '%s\n' "$server_public_key" \
        | grep -Eo '[A-Za-z0-9+/]{42,43}=' | head -n 1)

    if [ -z "$server_public_key" ]; then
        echo_error "Could not retrieve the server public key."
    fi

    echo_info "Assembling client configuration locally..."
    client_config_file="${CLIENT_CONFIG_OUTPUT:-${SCRIPT_DIR}/client.conf}"
    umask 077
    cat > "$client_config_file" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${WG_CLIENT_ADDRESS}
DNS = ${WG_CLIENT_DNS}

[Peer]
PublicKey = ${server_public_key}
Endpoint = ${public_ip}:${WG_PORT}
AllowedIPs = ${WG_CLIENT_ALLOWED_IPS}
PersistentKeepalive = ${WG_CLIENT_KEEPALIVE}
EOF

    echo ""
    echo "======================================================================"
    echo "Azure CLI Deployment Complete!"
    echo "======================================================================"
    echo ""
    echo "VM Details:"
    echo "  VM Name: $VM_NAME"
    echo "  Public IP: $public_ip"
    echo "  Location: ${LOCATION_DISPLAY_NAME:-$LOCATION} ($LOCATION)"
    echo "  VM Size: $VM_SIZE"
    echo "  Resource Group: $RESOURCE_GROUP_NAME"
    echo ""
    echo "Credentials (save these!):"
    echo "  Admin Username: $ADMIN_USER"
    echo ""
    echo "WireGuard Configuration:"
    echo "  Port: ${WG_PORT}/udp"
    echo "  Endpoint: ${public_ip}:${WG_PORT}"
    echo ""
    echo "Client Configuration:"
    echo "    ${client_config_file}"
    if [ -n "${AZUREPS_HOST_ENVIRONMENT:-}" ] || [ -n "${ACC_CLOUD:-}" ]; then
        echo ""
        echo "  From the Azure Cloud Shell, download the config file with the following command:"
        echo "    download \"${client_config_file}\""
        echo "  It lives on ephemeral storage and is removed when the session ends."
    fi
    echo ""
    echo "======================================================================"
}

main "$@"
