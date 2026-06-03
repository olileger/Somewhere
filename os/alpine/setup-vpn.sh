#!/bin/sh
set -euo pipefail

# =============================================================================
# Alpine Linux WireGuard VPN Server Setup Script
# =============================================================================
# This script configures a WireGuard VPN server on Alpine Linux.
# It:
#   1. Installs WireGuard and required tools
#   2. Configures the VPN server
#   3. Sets up admin user and password
#   4. Secures the system (no SSH, only WireGuard port exposed)
#   5. Enables auto-start on boot
#
# Usage:
#   ./setup-vpn.sh [admin_password] [client_username] [client_password]
#   Or set via environment variables:
#     ADMIN_PASSWORD, CLIENT_USERNAME, CLIENT_PASSWORD
#
# If no arguments provided, will prompt for input.
# =============================================================================

# -----------------------------------------------------------------------------
# Configuration variables
# -----------------------------------------------------------------------------
WG_INTERFACE="wg0"
WG_PORT="51820"
WG_NETWORK="10.8.0.0/24"
WG_SERVER_IP="10.8.0.1"
WG_CONFIG_DIR="/etc/wireguard"
WG_PRIVATE_KEY_FILE="${WG_CONFIG_DIR}/privatekey"
WG_PUBLIC_KEY_FILE="${WG_CONFIG_DIR}/publickey"
CLIENTS_DIR="${WG_CONFIG_DIR}/clients"
ADMIN_USER="admin"

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

echo_info() {
    echo "[INFO] $1"
}

echo_warn() {
    echo "[WARN] $1"
}

echo_error() {
    echo "[ERROR] $1" >&2
    exit 1
}

# -----------------------------------------------------------------------------
# Get credentials (from args, env, or prompt)
# -----------------------------------------------------------------------------

get_credentials() {
    # Check command line arguments
    if [ $# -ge 3 ]; then
        ADMIN_PASSWORD="$1"
        CLIENT_USERNAME="$2"
        CLIENT_PASSWORD="$3"
        return
    fi

    # Check environment variables
    if [ -n "${ADMIN_PASSWORD:-}" ] && [ -n "${CLIENT_USERNAME:-}" ] && [ -n "${CLIENT_PASSWORD:-}" ]; then
        return
    fi

    # Prompt for input (only works in interactive mode)
    if [ -t 0 ]; then
        while true; do
            printf "Enter admin/sudo password for the VM: "
            read -r ADMIN_PASSWORD
            if [ -n "$ADMIN_PASSWORD" ]; then
                break
            fi
            echo_error "Password cannot be empty."
        done

        while true; do
            printf "Confirm admin/sudo password: "
            read -r ADMIN_PASSWORD_CONFIRM
            if [ -n "$ADMIN_PASSWORD_CONFIRM" ]; then
                if [ "$ADMIN_PASSWORD" = "$ADMIN_PASSWORD_CONFIRM" ]; then
                    break
                else
                    echo_error "Passwords do not match."
                fi
            fi
            echo_error "Password cannot be empty."
        done

        while true; do
            printf "Enter client username for VPN connection: "
            read -r CLIENT_USERNAME
            if [ -n "$CLIENT_USERNAME" ]; then
                break
            fi
            echo_error "Username cannot be empty."
        done

        while true; do
            printf "Enter client password for VPN connection: "
            read -r CLIENT_PASSWORD
            if [ -n "$CLIENT_PASSWORD" ]; then
                break
            fi
            echo_error "Password cannot be empty."
        done
    else
        echo_error "No credentials provided and not in interactive mode."
        echo_error "Please provide ADMIN_PASSWORD, CLIENT_USERNAME, and CLIENT_PASSWORD as environment variables."
    fi
}

# -----------------------------------------------------------------------------
# Main setup
# -----------------------------------------------------------------------------

get_credentials "$@"

# -----------------------------------------------------------------------------
# Step 1: Install required packages
# -----------------------------------------------------------------------------

echo_info "Updating package index and installing WireGuard..."
apk update
apk add --no-cache wireguard-tools iptables ip6tables openrc coreutils

# Ensure wireguard kernel module is loaded
if ! modprobe wireguard 2>/dev/null; then
    echo_warn "WireGuard kernel module not available. Trying to load tun module..."
    modprobe tun || echo_error "Failed to load tun module. Your kernel may not support WireGuard."
fi

# -----------------------------------------------------------------------------
# Step 2: Set up admin user
# -----------------------------------------------------------------------------

echo_info "Creating admin user..."
if ! id "$ADMIN_USER" &>/dev/null; then
    adduser -D -s /bin/ash "$ADMIN_USER" || echo_error "Failed to create admin user."
fi

echo "${ADMIN_USER}:${ADMIN_PASSWORD}" | chpasswd || echo_error "Failed to set password."

# Add to sudoers (Alpine uses doas instead of sudo)
echo "${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/doas.d/admin
chmod 600 /etc/doas.d/admin

# -----------------------------------------------------------------------------
# Step 3: Store client credentials (for reference)
# Note: WireGuard uses public/private keys for authentication, not username/password.
# -----------------------------------------------------------------------------

mkdir -p "$WG_CONFIG_DIR"
mkdir -p "$CLIENTS_DIR"

echo "${CLIENT_USERNAME}:${CLIENT_PASSWORD}" > "${WG_CONFIG_DIR}/client_credentials.txt"
chmod 600 "${WG_CONFIG_DIR}/client_credentials.txt"

echo_warn "IMPORTANT: WireGuard uses public/private keys for authentication."
echo_warn "The username/password ('${CLIENT_USERNAME}') are for your reference only."
echo_warn "The actual VPN connection requires the client configuration file."

# -----------------------------------------------------------------------------
# Step 4: Generate WireGuard keys
# -----------------------------------------------------------------------------

echo_info "Generating WireGuard server keys..."

# Server keys
wg genkey | tee "$WG_PRIVATE_KEY_FILE" | wg pubkey > "$WG_PUBLIC_KEY_FILE"
chmod 600 "$WG_PRIVATE_KEY_FILE"

# Client keys (generate one for the client)
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

# Save client keys
CLIENT_PRIVATE_KEY_FILE="${CLIENTS_DIR}/${CLIENT_USERNAME}_privatekey"
CLIENT_PUBLIC_KEY_FILE="${CLIENTS_DIR}/${CLIENT_USERNAME}_publickey"
echo "$CLIENT_PRIVATE_KEY" > "$CLIENT_PRIVATE_KEY_FILE"
echo "$CLIENT_PUBLIC_KEY" > "$CLIENT_PUBLIC_KEY_FILE"
chmod 600 "$CLIENT_PRIVATE_KEY_FILE"

# -----------------------------------------------------------------------------
# Step 5: Configure WireGuard server
# -----------------------------------------------------------------------------

echo_info "Configuring WireGuard server..."

# Server IP
WG_SERVER_PRIVATE_KEY=$(cat "$WG_PRIVATE_KEY_FILE")

# Create server config
cat > "${WG_CONFIG_DIR}/${WG_INTERFACE}.conf" <<EOF
[Interface]
PrivateKey = ${WG_SERVER_PRIVATE_KEY}
Address = ${WG_SERVER_IP}/24
ListenPort = ${WG_PORT}
PostUp = iptables -A FORWARD -i ${WG_INTERFACE} -j ACCEPT; \
          iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE; \
          ip6tables -A FORWARD -i ${WG_INTERFACE} -j ACCEPT; \
          ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i ${WG_INTERFACE} -j ACCEPT; \
           iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE; \
           ip6tables -D FORWARD -i ${WG_INTERFACE} -j ACCEPT; \
           ip6tables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = 10.8.0.2/32
# Peer identifier (for reference)
# Client: ${CLIENT_USERNAME}
EOF

chmod 600 "${WG_CONFIG_DIR}/${WG_INTERFACE}.conf"

# -----------------------------------------------------------------------------
# Step 6: Enable IP forwarding
# -----------------------------------------------------------------------------

echo_info "Enabling IP forwarding..."
cat >> /etc/sysctl.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF

sysctl -p

# -----------------------------------------------------------------------------
# Step 7: Configure firewall (only allow WireGuard port)
# -----------------------------------------------------------------------------

echo_info "Configuring firewall..."

# Flush existing rules
iptables -F
iptables -X
ip6tables -F
ip6tables -X

# Default policies: DROP
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -i lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow WireGuard port (UDP)
iptables -A INPUT -p udp --dport ${WG_PORT} -j ACCEPT
ip6tables -A INPUT -p udp --dport ${WG_PORT} -j ACCEPT

# Allow ICMP (ping)
iptables -A INPUT -p icmp -j ACCEPT
ip6tables -A INPUT -p icmpv6 -j ACCEPT

# Save iptables rules
apk add --no-cache iptables-persistent 2>/dev/null || true
mkdir -p /etc/iptables
 iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

# Enable iptables-persistent
rc-update add iptables default 2>/dev/null || true
rc-update add ip6tables default 2>/dev/null || true

# -----------------------------------------------------------------------------
# Step 8: Disable SSH (only allow WireGuard)
# -----------------------------------------------------------------------------

echo_info "Disabling SSH for security..."
rc-service sshd stop 2>/dev/null || true
rc-update del sshd default 2>/dev/null || true

# Remove openssh if installed
apk del openssh 2>/dev/null || true

# -----------------------------------------------------------------------------
# Step 9: Enable WireGuard to start on boot
# -----------------------------------------------------------------------------

echo_info "Configuring WireGuard to start on boot..."

# Method 1: Use wg-quick directly (preferred)
rc-update add wg-quick.${WG_INTERFACE} default

# Method 2: Create custom startup script for OpenRC
cat > /etc/local.d/wg-start.start <<EOF
#!/sbin/openrc-run
name="wg-start"
depend() {
    need net
    before firewall
}
start() {
    ebegin "Starting WireGuard"
    wg-quick up ${WG_INTERFACE}
    eend
}
stop() {
    ebegin "Stopping WireGuard"
    wg-quick down ${WG_INTERFACE}
    eend
}
EOF

chmod +x /etc/local.d/wg-start.start
rc-update add wg-start default

# -----------------------------------------------------------------------------
# Step 10: Generate client configuration
# -----------------------------------------------------------------------------

echo_info "Generating client configuration..."

CLIENT_IP="10.8.0.2"

# Try to get public IP from cloud metadata
SERVER_PUBLIC_IP=""

# Try GCP metadata
if curl -s -m 2 http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip -H "Metadata-Flavor: Google" 2>/dev/null | grep -q '.'; then
    SERVER_PUBLIC_IP=$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip -H "Metadata-Flavor: Google")
# Try AWS metadata
elif curl -s -m 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null | grep -q '.'; then
    SERVER_PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
# Try Azure metadata
elif curl -s -m 2 http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress -H "Metadata:true" 2>/dev/null | grep -q '.'; then
    SERVER_PUBLIC_IP=$(curl -s http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress -H "Metadata:true")
fi

if [ -z "$SERVER_PUBLIC_IP" ]; then
    SERVER_PUBLIC_IP="YOUR_SERVER_IP"
fi

cat > "${CLIENTS_DIR}/${CLIENT_USERNAME}.conf" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${CLIENT_IP}/24
DNS = 8.8.8.8, 8.8.4.4

[Peer]
PublicKey = $(cat ${WG_PUBLIC_KEY_FILE})
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

chmod 600 "${CLIENTS_DIR}/${CLIENT_USERNAME}.conf"

# Also create a combined config file with credentials for reference
cat > "${CLIENTS_DIR}/${CLIENT_USERNAME}-full.conf" <<EOF
# WireGuard Client Configuration
# Username: ${CLIENT_USERNAME}
# Password: ${CLIENT_PASSWORD}
# (Note: WireGuard uses public/private keys for authentication, not username/password)

[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${CLIENT_IP}/24
DNS = 8.8.8.8, 8.8.4.4

[Peer]
PublicKey = $(cat ${WG_PUBLIC_KEY_FILE})
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

chmod 600 "${CLIENTS_DIR}/${CLIENT_USERNAME}-full.conf"

# -----------------------------------------------------------------------------
# Step 11: Display summary
# -----------------------------------------------------------------------------

echo ""
echo "======================================================================"
echo "WireGuard VPN Server Setup Complete!"
echo "======================================================================"
echo ""
echo "Admin credentials (save these!):"
echo "  Username: ${ADMIN_USER}"
echo "  Password: [the password provided]"
echo ""
echo "Client VPN configuration (save this!):"
echo "  Username: ${CLIENT_USERNAME}"
echo "  Password: [the password provided]"
echo ""
echo "Client config files:"
echo "  - ${CLIENTS_DIR}/${CLIENT_USERNAME}.conf (WireGuard config)"
echo "  - ${CLIENTS_DIR}/${CLIENT_USERNAME}-full.conf (with credentials reference)"
echo ""
echo "To connect with WireGuard client:"
echo "  1. Import the .conf file into your WireGuard client"
echo "  2. The username/password are for reference only"
echo "  3. Authentication is done via the private key in the config file"
echo ""
echo "Server public IP: ${SERVER_PUBLIC_IP}"
echo "WireGuard port: ${WG_PORT}"
echo ""
echo "Security notes:"
echo "  - SSH is DISABLED (only WireGuard port ${WG_PORT}/udp is open)"
echo "  - IP forwarding is enabled"
echo "  - Firewall rules are persistent"
echo "  - WireGuard will start automatically on boot"
echo ""
echo "IMPORTANT: If you lose the client config file, you will not be able to connect!"
echo "======================================================================"

# -----------------------------------------------------------------------------
# Step 12: Start WireGuard now
# -----------------------------------------------------------------------------

echo_info "Starting WireGuard..."
wg-quick up "$WG_INTERFACE" 2>/dev/null || true

echo_info "Setup complete!"
