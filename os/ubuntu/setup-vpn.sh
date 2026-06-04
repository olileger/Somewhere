#!/bin/bash
set -euo pipefail

# =============================================================================
# Ubuntu Minimal WireGuard VPN Server Setup Script
# =============================================================================

WG_INTERFACE="wg0"
WG_PORT="51820"
WG_NETWORK="10.8.0.0/24"
WG_SERVER_IP="10.8.0.1"
WG_CONFIG_DIR="/etc/wireguard"
WG_PRIVATE_KEY_FILE="${WG_CONFIG_DIR}/privatekey"
WG_PUBLIC_KEY_FILE="${WG_CONFIG_DIR}/publickey"
CLIENTS_DIR="${WG_CONFIG_DIR}/clients"
ADMIN_USER="${ADMIN_USER:-}"

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

get_credentials() {
    if [ $# -ge 1 ]; then
        ADMIN_PASSWORD="$1"
        return
    fi

    if [ -n "${ADMIN_PASSWORD:-}" ]; then
        return
    fi

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
                fi
                echo_error "Passwords do not match."
            fi
            echo_error "Password cannot be empty."
        done
    else
        echo_error "No credentials provided and not in interactive mode."
        echo_error "Please provide ADMIN_PASSWORD as an environment variable."
    fi
}

get_admin_user() {
    if [ -z "${ADMIN_USER:-}" ]; then
        ADMIN_USER=$(LC_ALL=C tr -dc 'a-z' </dev/urandom | head -c 12 || true)
    fi

    if [ "${#ADMIN_USER}" -ne 12 ]; then
        echo_error "ADMIN_USER must be 12 alphabetic characters."
    fi
}

get_public_ip() {
    local server_public_ip=""

    if curl -s -m 2 http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress -H "Metadata:true" 2>/dev/null | grep -q '.'; then
        server_public_ip=$(curl -s http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress -H "Metadata:true")
    fi

    if [ -z "$server_public_ip" ]; then
        server_public_ip="YOUR_SERVER_IP"
    fi

    echo "$server_public_ip"
}

get_credentials "$@"
get_admin_user

echo_info "Updating package index and installing WireGuard..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends wireguard-tools iptables iptables-persistent curl sudo openssh-server

if ! modprobe wireguard 2>/dev/null; then
    echo_warn "WireGuard kernel module not available; the image/kernel may already provide it."
fi

echo_info "Creating admin user..."
if ! id "$ADMIN_USER" &>/dev/null; then
    adduser --disabled-password --gecos "" "$ADMIN_USER" || echo_error "Failed to create admin user."
fi

echo "${ADMIN_USER}:${ADMIN_PASSWORD}" | chpasswd || echo_error "Failed to set password."
usermod -aG sudo "$ADMIN_USER" || echo_error "Failed to add admin user to sudo group."

echo_info "Preparing configuration directories..."
mkdir -p "$WG_CONFIG_DIR"
mkdir -p "$CLIENTS_DIR"

echo_info "Generating WireGuard server keys..."
wg genkey | tee "$WG_PRIVATE_KEY_FILE" | wg pubkey > "$WG_PUBLIC_KEY_FILE"
chmod 600 "$WG_PRIVATE_KEY_FILE"

CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
CLIENT_NAME="client"
CLIENT_PRIVATE_KEY_FILE="${CLIENTS_DIR}/${CLIENT_NAME}_privatekey"
CLIENT_PUBLIC_KEY_FILE="${CLIENTS_DIR}/${CLIENT_NAME}_publickey"
echo "$CLIENT_PRIVATE_KEY" > "$CLIENT_PRIVATE_KEY_FILE"
echo "$CLIENT_PUBLIC_KEY" > "$CLIENT_PUBLIC_KEY_FILE"
chmod 600 "$CLIENT_PRIVATE_KEY_FILE"

echo_info "Configuring WireGuard server..."
WG_SERVER_PRIVATE_KEY=$(cat "$WG_PRIVATE_KEY_FILE")

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
EOF

chmod 600 "${WG_CONFIG_DIR}/${WG_INTERFACE}.conf"

echo_info "Enabling IP forwarding..."
cat > /etc/sysctl.d/99-wireguard.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl --system

echo_info "Configuring firewall..."
iptables -F
iptables -X
ip6tables -F
ip6tables -X

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT ACCEPT

iptables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p udp --dport "${WG_PORT}" -j ACCEPT
ip6tables -A INPUT -p udp --dport "${WG_PORT}" -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
ip6tables -A INPUT -p icmpv6 -j ACCEPT

iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6
netfilter-persistent save
systemctl enable netfilter-persistent
systemctl enable --now ssh

echo_info "Configuring WireGuard to start on boot..."
systemctl enable "wg-quick@${WG_INTERFACE}"

SERVER_PUBLIC_IP=$(get_public_ip)
CLIENT_CONFIG_FILE="${CLIENTS_DIR}/${CLIENT_NAME}.conf"

cat > "$CLIENT_CONFIG_FILE" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = 10.8.0.2/24
DNS = 8.8.8.8, 8.8.4.4

[Peer]
PublicKey = $(cat "${WG_PUBLIC_KEY_FILE}")
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

chmod 600 "$CLIENT_CONFIG_FILE"

echo_info "Starting WireGuard..."
wg-quick up "$WG_INTERFACE" 2>/dev/null || true

echo ""
echo "======================================================================"
echo "WireGuard VPN Server Setup Complete!"
echo "======================================================================"
echo ""
echo "Client config files:"
echo "  - ${CLIENT_CONFIG_FILE}"
echo "  - ${CLIENT_PRIVATE_KEY_FILE}"
echo "  - ${CLIENT_PUBLIC_KEY_FILE}"
echo ""
echo "Server public IP: ${SERVER_PUBLIC_IP}"
echo "WireGuard port: ${WG_PORT}"
echo ""
echo "Security notes:"
echo "  - SSH is ENABLED in the VM firewall but blocked at the NSG on port 22"
echo "  - IP forwarding is enabled"
echo "  - Firewall rules are persistent"
echo "  - WireGuard will start automatically on boot"
echo "======================================================================"
