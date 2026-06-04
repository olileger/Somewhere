#!/bin/bash
set -euo pipefail

# =============================================================================
# GCP Preemptible VM Provisioning for Alpine WireGuard VPN
# =============================================================================
# This script provisions a minimal Preemptible VM on GCP with Alpine Linux
# and configures it as a WireGuard VPN server.
#
# Requirements:
#   - gcloud CLI installed and configured (gcloud auth login)
#   - gcloud project set (gcloud config set project PROJECT_ID)
#
# Usage: ./provision.sh
# =============================================================================

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
REGION="europe-west9"  # Paris, equivalent to Azure France Central
ZONE="${REGION}-a"   # Availability zone
MACHINE_TYPE="f1-micro"  # Cheapest option (1 vCPU, 600MB RAM)
# Alternative: e2-micro (2 vCPU, 1GB RAM) - more available but slightly more expensive
DISK_SIZE="10"  # 10GB pd-standard (minimum practical size)
DISK_TYPE="pd-standard"  # HDD, cheapest option
# Alternative: pd-balanced (SSD) - sometimes cheaper for small sizes
INSTANCE_NAME="wireguard-vpn-alpine"
FIREWALL_RULE_NAME="somewhere"
NETWORK_NAME="default"  # Use default network for simplicity
SUBNETWORK_NAME="default"
ADMIN_USER=""

# WireGuard port
WG_PORT="51820"

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

echo_info() {
    echo "[GCP INFO] $1"
}

echo_error() {
    echo "[GCP ERROR] $1" >&2
    exit 1
}

# Check if gcloud CLI is installed
check_gcloud_cli() {
    if ! command -v gcloud &> /dev/null; then
        echo_error "gcloud CLI is not installed. Please install it first."
        echo_error "See: https://cloud.google.com/sdk/docs/install"
    fi
}

# Check if logged in
check_gcloud_login() {
    if ! gcloud auth list --format="value(account)" | grep -q "@"; then
        echo_error "Not logged in to gcloud. Please run 'gcloud auth login' first."
    fi
}

# Check if project is set
check_gcloud_project() {
    local project=$(gcloud config get-value project 2>/dev/null)
    if [ -z "$project" ]; then
        echo_error "No gcloud project set. Please run 'gcloud config set project PROJECT_ID' first."
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
echo "GCP Preemptible VM Provisioning for WireGuard VPN"
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

check_gcloud_cli
check_gcloud_login
check_gcloud_project

PROJECT_ID=$(gcloud config get-value project)
echo_info "Using project: $PROJECT_ID"

# -----------------------------------------------------------------------------
# Step 1: Find Alpine Linux image
# -----------------------------------------------------------------------------

echo_info "Searching for Alpine Linux image..."
ALPINE_IMAGE=$(gcloud compute images list \
    --filter="family=alpine-3-18" \
    --filter="architecture=X86_64" \
    --format="value(name)" \
    --limit=1 \
    2>/dev/null | head -n 1)

if [ -z "$ALPINE_IMAGE" ]; then
    # Try with latest alpine
    ALPINE_IMAGE=$(gcloud compute images list \
        --filter="family=alpine" \
        --filter="architecture=X86_64" \
        --format="value(name)" \
        --limit=1 \
        2>/dev/null | head -n 1)
fi

if [ -z "$ALPINE_IMAGE" ]; then
    # Fallback to a known image family
    ALPINE_IMAGE="alpine-3-18-x86_64"
    echo_info "Using image family: $ALPINE_IMAGE"
else
    echo_info "Found Alpine image: $ALPINE_IMAGE"
fi

# -----------------------------------------------------------------------------
# Step 2: Create firewall rule (only WireGuard port open)
# -----------------------------------------------------------------------------

echo_info "Creating firewall rule..."

# Check if rule already exists
if ! gcloud compute firewall-rules describe "$FIREWALL_RULE_NAME" --format="value(name)" &> /dev/null; then
    gcloud compute firewall-rules create "$FIREWALL_RULE_NAME" \
        --allow="udp:${WG_PORT}" \
        --source-ranges="0.0.0.0/0" \
        --description="WireGuard VPN - Only port ${WG_PORT}/udp" \
        --target-tags="wireguard-vpn" \
        --network="$NETWORK_NAME"
    echo_info "Firewall rule created: $FIREWALL_RULE_NAME"
else
    echo_info "Using existing firewall rule: $FIREWALL_RULE_NAME"
fi

# Add ICMP rule if not exists
if ! gcloud compute firewall-rules describe "allow-icmp-${USER}" --format="value(name)" &> /dev/null; then
    gcloud compute firewall-rules create "allow-icmp-${USER}" \
        --allow="icmp" \
        --source-ranges="0.0.0.0/0" \
        --description="Allow ICMP (ping)" \
        --target-tags="wireguard-vpn" \
        --network="$NETWORK_NAME"
    echo_info "ICMP firewall rule created."
else
    echo_info "Using existing ICMP firewall rule."
fi

# -----------------------------------------------------------------------------
# Step 3: Encode setup script and credentials for startup script
# -----------------------------------------------------------------------------

echo_info "Encoding setup script and credentials..."

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
# Step 4: Create the VM (Preemptible)
# -----------------------------------------------------------------------------

echo_info "Launching Preemptible VM..."

# Create startup script
STARTUP_SCRIPT=$(cat <<EOF
#!/bin/bash
set -euo pipefail

# Install base64 decoder (Alpine uses BusyBox, may already have it)
apk add --no-cache coreutils 2>/dev/null || true

# Decode credentials
export ADMIN_USER="$ADMIN_USER"
export ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d)

# Decode and run setup script
echo "$SETUP_SCRIPT_BASE64" | base64 -d > /tmp/setup-vpn.sh
chmod +x /tmp/setup-vpn.sh
/tmp/setup-vpn.sh
rm /tmp/setup-vpn.sh

# Signal completion
touch /tmp/vpn-setup-complete
EOF
)

# Create the instance
INSTANCE_ID=$(gcloud compute instances create "$INSTANCE_NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image="$ALPINE_IMAGE" \
    --image-project="alpine-cloud" \
    --boot-disk-size="${DISK_SIZE}GB" \
    --boot-disk-type="$DISK_TYPE" \
    --provisioning-model="SPOT" \
    --tags="wireguard-vpn" \
    --metadata="startup-script=$(echo "$STARTUP_SCRIPT" | base64 -w0 2>/dev/null || echo "$STARTUP_SCRIPT" | base64 | tr -d '\n')" \
    --format="value(id)" \
    2>/dev/null)

echo_info "VM created: $INSTANCE_ID"

# -----------------------------------------------------------------------------
# Step 5: Reserve static external IP
# -----------------------------------------------------------------------------

echo_info "Reserving static external IP..."

# Wait a bit for the instance to get an external IP
sleep 10

# Get the current external IP
CURRENT_IP=$(gcloud compute instances describe "$INSTANCE_NAME" \
    --zone="$ZONE" \
    --format="value(networkInterfaces[0].accessConfigs[0].natIP)" \
    2>/dev/null)

if [ -n "$CURRENT_IP" ]; then
    # Create a static IP
    STATIC_IP_NAME="${INSTANCE_NAME}-ip"
    if ! gcloud compute addresses describe "$STATIC_IP_NAME" --region="$REGION" &> /dev/null; then
        gcloud compute addresses create "$STATIC_IP_NAME" \
            --region="$REGION"
        STATIC_IP=$(gcloud compute addresses describe "$STATIC_IP_NAME" --region="$REGION" --format="value(address)")
        
        # Associate static IP with instance
        gcloud compute instances add-access-config \
            "$INSTANCE_NAME" \
            --zone="$ZONE" \
            --access-config-name="External NAT" \
            --address="$STATIC_IP"
        
        CURRENT_IP="$STATIC_IP"
        echo_info "Static IP reserved and associated: $CURRENT_IP"
    else
        STATIC_IP=$(gcloud compute addresses describe "$STATIC_IP_NAME" --region="$REGION" --format="value(address)")
        echo_info "Using existing static IP: $STATIC_IP"
        CURRENT_IP="$STATIC_IP"
    fi
else
    echo_error "Could not get external IP for the instance."
fi

# -----------------------------------------------------------------------------
# Step 6: Wait for VM to be running and setup to complete
# -----------------------------------------------------------------------------

echo_info "Waiting for VM to be running..."
gcloud compute instances wait --zone="$ZONE" --for="RUNNING" "$INSTANCE_NAME" --timeout=300s

echo_info "Waiting for VPN setup to complete (this may take 2-3 minutes)..."
sleep 60

# -----------------------------------------------------------------------------
# Step 7: Display summary
# -----------------------------------------------------------------------------

echo ""
echo "======================================================================"
echo "GCP Preemptible VM Provisioning Complete!"
echo "======================================================================"
echo ""
echo "VM Details:"
echo "  Instance Name: $INSTANCE_NAME"
echo "  Public IP: $CURRENT_IP"
echo "  Zone: $ZONE"
echo "  Machine Type: $MACHINE_TYPE"
echo "  Project: $PROJECT_ID"
echo ""
echo "Credentials (save these!):"
echo "  Admin Username: $ADMIN_USER"
echo "  Admin Password: [the password you entered]"
echo ""
echo "WireGuard Configuration:"
echo "  Port: ${WG_PORT}/udp"
echo "  Endpoint: ${CURRENT_IP}:${WG_PORT}"
echo ""
echo "Client Configuration:"
echo "  The client config file is generated on the server at:"
echo "    /etc/wireguard/clients/client.conf"
echo "    /etc/wireguard/clients/client_privatekey"
echo "    /etc/wireguard/clients/client_publickey"
echo ""
echo "  To retrieve the client config file:"
echo "    1. Temporarily add a firewall rule for SSH (port 22):"
echo "       gcloud compute firewall-rules create allow-ssh-temp \\"
echo "         --allow=tcp:22 --source-ranges=YOUR_IP/32 \\"
echo "         --target-tags=wireguard-vpn --network=$NETWORK_NAME"
echo "    2. SSH to the instance using:"
echo "       gcloud compute ssh $INSTANCE_NAME --zone $ZONE --username $ADMIN_USER"
echo "    3. Get the config: cat /etc/wireguard/clients/client.conf"
echo "    4. Remove SSH access:"
echo "       gcloud compute firewall-rules delete allow-ssh-temp"
echo ""
echo "Alternatively, use the GCP Serial Console:"
echo "  gcloud compute connect-to-serial-port $INSTANCE_NAME --zone $ZONE"
echo ""
echo "Cost Estimate:"
echo "  VM (Preemptible f1-micro): ~\$0.0044/hour (varies by region)"
echo "  Disk (10GB pd-standard): ~\$0.40/month"
echo "  Static IP: Free (while attached to running VM)"
echo ""
echo "To terminate the VM:"
echo "  gcloud compute instances delete $INSTANCE_NAME --zone $ZONE --delete-disks=all"
echo "  gcloud compute addresses delete $STATIC_IP_NAME --region $REGION"
echo "  gcloud compute firewall-rules delete $FIREWALL_RULE_NAME"
echo "  gcloud compute firewall-rules delete allow-icmp-${USER}"
echo ""
echo "Note: Preemptible VMs may be terminated at any time by GCP."
echo "They typically run for 24 hours but can be stopped with short notice."
echo "======================================================================"
