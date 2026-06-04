#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/azuredeploy.json"

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
ADMIN_USER="${ADMIN_USER:-}"

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

check_azure_login() {
    if ! az account show &> /dev/null; then
        echo_error "Not logged in to Azure. Please run 'az login' first."
    fi
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r/\\r/g; s/\t/\\t/g'
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

write_parameters_file() {
    local params_file="$1"

    cat > "$params_file" <<EOF
{
  "resourceGroupName": { "value": "$(json_escape "$RESOURCE_GROUP_NAME")" },
  "location": { "value": "$(json_escape "$LOCATION")" },
  "vmSize": { "value": "$(json_escape "$VM_SIZE")" },
  "vmName": { "value": "$(json_escape "$VM_NAME")" },
  "networkName": { "value": "$(json_escape "$NETWORK_NAME")" },
  "subnetName": { "value": "$(json_escape "$SUBNET_NAME")" },
  "publicIpName": { "value": "$(json_escape "$PUBLIC_IP_NAME")" },
  "networkSecurityGroupName": { "value": "$(json_escape "$NETWORK_SECURITY_GROUP_NAME")" },
  "adminUsername": { "value": "$(json_escape "$ADMIN_USER")" },
  "adminPassword": { "value": "$(json_escape "$ADMIN_PASSWORD")" },
  "diskSizeGb": { "value": $DISK_SIZE_GB },
  "diskType": { "value": "$(json_escape "$DISK_TYPE")" },
  "wgPort": { "value": "$(json_escape "$WG_PORT")" }
}
EOF
}

main() {
    local params_file deployment_name public_ip

    echo "======================================================================"
    echo "Azure ARM Deployment for WireGuard VPN"
    echo "======================================================================"

    check_azure_cli
    check_azure_login

    if [ ! -f "$TEMPLATE_FILE" ]; then
        echo_error "ARM template not found at: $TEMPLATE_FILE"
    fi

    select_location
    generate_admin_user
    prompt_admin_password

    params_file="$(mktemp)"
    deployment_name="${RESOURCE_GROUP_NAME}-$(date +%Y%m%d%H%M%S)"

    trap 'rm -f "$params_file"' EXIT
    write_parameters_file "$params_file"

    echo_info "Simulating subscription deployment with az deployment sub what-if..."
    if ! az deployment sub what-if \
        --name "${deployment_name}-whatif" \
        --location "$LOCATION" \
        --template-file "$TEMPLATE_FILE" \
        --parameters @"$params_file" \
        --result-format FullResourcePayloads \
        --no-pretty-print; then
        echo_error "Deployment simulation failed; nothing has been deployed."
    fi

    echo_info "Simulation passed. Deploying resources..."
    public_ip=$(az deployment sub create \
        --name "$deployment_name" \
        --location "$LOCATION" \
        --template-file "$TEMPLATE_FILE" \
        --parameters @"$params_file" \
        --query "properties.outputs.publicIpAddress.value" \
        --output tsv)

    if [ -z "$public_ip" ]; then
        public_ip=$(az network public-ip show \
            --name "$PUBLIC_IP_NAME" \
            --resource-group "$RESOURCE_GROUP_NAME" \
            --query ipAddress \
            --output tsv)
    fi

    echo ""
    echo "======================================================================"
    echo "Azure ARM Deployment Complete!"
    echo "======================================================================"
    echo ""
    echo "VM Details:"
    echo "  VM Name: $VM_NAME"
    echo "  Public IP: $public_ip"
    echo "  Location: ${LOCATION_DISPLAY_NAME:-$LOCATION} ($LOCATION)"
    echo "  VM Size: $VM_SIZE (Spot)"
    echo "  Resource Group: $RESOURCE_GROUP_NAME"
    echo ""
    echo "Credentials (save these!):"
    echo "  Admin Username: $ADMIN_USER"
    echo "  Admin Password: [the password you entered]"
    echo ""
    echo "WireGuard Configuration:"
    echo "  Port: ${WG_PORT}/udp"
    echo "  Endpoint: ${public_ip}:${WG_PORT}"
    echo ""
    echo "Client Configuration:"
    echo "  The client config file is generated on the server at:"
    echo "    /etc/wireguard/clients/client.conf"
    echo "    /etc/wireguard/clients/client_privatekey"
    echo "    /etc/wireguard/clients/client_publickey"
    echo ""
    echo "To terminate the deployment:"
    echo "  az deployment sub delete --name $deployment_name"
    echo "  az group delete --name $RESOURCE_GROUP_NAME --yes --no-wait"
    echo ""
    echo "Note: Spot VMs may be evicted at any time by Azure."
    echo "======================================================================"
}

main "$@"
