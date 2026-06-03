#!/bin/bash
set -euo pipefail

# =============================================================================
# AWS Spot Instance Provisioning for Alpine WireGuard VPN
# =============================================================================
# This script provisions a minimal Spot instance on AWS with Alpine Linux
# and configures it as a WireGuard VPN server.
#
# Requirements:
#   - AWS CLI installed and configured (aws configure)
#   - jq for JSON parsing (install with: sudo apt install jq / brew install jq)
#
# Usage: ./provision.sh
# =============================================================================

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
REGION="us-east-1"  # Change to your preferred region
INSTANCE_TYPE="t4g.nano"  # ARM-based, cheapest option (512MB RAM)
# Alternative x86 options if ARM not available: t3.micro (1GB RAM)
VOLUME_SIZE="5"  # 5GB (minimum for Alpine + WireGuard)
VOLUME_TYPE="gp2"  # gp2 is usually cheapest for small volumes
KEY_NAME="vpn-key-${USER}"  # SSH key name (will be created if not exists)
SECURITY_GROUP_NAME="vpn-wg-sg-${USER}"
INSTANCE_NAME="wireguard-vpn-alpine"
TAG_NAME="WireGuardVPN"

# WireGuard port
WG_PORT="51820"

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

echo_info() {
    echo "[AWS INFO] $1"
}

echo_error() {
    echo "[AWS ERROR] $1" >&2
    exit 1
}

# Check if AWS CLI is installed
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        echo_error "AWS CLI is not installed. Please install it first."
        echo_error "See: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    fi
}

# Check if jq is installed
check_jq() {
    if ! command -v jq &> /dev/null; then
        echo_error "jq is not installed. Please install it (sudo apt install jq / brew install jq)."
    fi
}

# -----------------------------------------------------------------------------
# Get credentials
# -----------------------------------------------------------------------------

echo "======================================================================"
echo "AWS Spot Instance Provisioning for WireGuard VPN"
echo "======================================================================"

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

while true; do
    read -r -p "Enter client username for VPN connection: " CLIENT_USERNAME
    if [ -n "$CLIENT_USERNAME" ]; then
        break
    fi
    echo_error "Username cannot be empty."
done

while true; do
    read -r -s -p "Enter client password for VPN connection: " CLIENT_PASSWORD
    echo
    if [ -n "$CLIENT_PASSWORD" ]; then
        break
    fi
    echo_error "Password cannot be empty."
done

# -----------------------------------------------------------------------------
# Initialize
# -----------------------------------------------------------------------------

check_aws_cli
check_jq

# Set default region if not configured
export AWS_DEFAULT_REGION="$REGION"

# -----------------------------------------------------------------------------
# Step 1: Create SSH key (if not exists)
# -----------------------------------------------------------------------------

echo_info "Checking SSH key..."
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" &> /dev/null; then
    echo_info "Creating new SSH key: $KEY_NAME"
    aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text --region "$REGION" > "${KEY_NAME}.pem"
    chmod 400 "${KEY_NAME}.pem"
    echo_info "SSH key saved to: ${KEY_NAME}.pem"
else
    echo_info "Using existing SSH key: $KEY_NAME"
fi

# -----------------------------------------------------------------------------
# Step 2: Create security group (only WireGuard port open)
# -----------------------------------------------------------------------------

echo_info "Creating security group..."
SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name "$SECURITY_GROUP_NAME" \
    --description "WireGuard VPN - Only port ${WG_PORT}/udp" \
    --region "$REGION" \
    --query 'GroupId' \
    --output text)

echo_info "Security group created: $SECURITY_GROUP_ID"

# Add rule for WireGuard (UDP)
aws ec2 authorize-security-group-ingress \
    --group-id "$SECURITY_GROUP_ID" \
    --protocol udp \
    --port "$WG_PORT" \
    --cidr 0.0.0.0/0 \
    --region "$REGION"

# Add rule for ICMP (ping)
aws ec2 authorize-security-group-ingress \
    --group-id "$SECURITY_GROUP_ID" \
    --protocol icmp \
    --cidr 0.0.0.0/0 \
    --region "$REGION"

echo_info "Security group rules configured (only UDP/${WG_PORT} and ICMP)."

# -----------------------------------------------------------------------------
# Step 3: Find Alpine Linux AMI
# -----------------------------------------------------------------------------

echo_info "Searching for Alpine Linux AMI..."
ALPINE_AMI=$(aws ec2 describe-images \
    --filters "Name=name,Values=alpine-3-18*" "Name=virtualization-type,Values=hvm" "Name=root-device-type,Values=ebs" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text \
    --region "$REGION" 2>/dev/null)

if [ -z "$ALPINE_AMI" ]; then
    # Try with different pattern
    ALPINE_AMI=$(aws ec2 describe-images \
        --owners 509394713598 \
        --filters "Name=name,Values=alpine-*" "Name=virtualization-type,Values=hvm" \
        --query "sort_by(Images, &CreationDate)[-1].ImageId" \
        --output text \
        --region "$REGION")
fi

if [ -z "$ALPINE_AMI" ]; then
    echo_error "Could not find Alpine Linux AMI in region $REGION."
    echo_error "Try changing the REGION variable or check available AMIs with:"
    echo_error "  aws ec2 describe-images --owners 509394713598 --region $REGION"
fi

echo_info "Found Alpine AMI: $ALPINE_AMI"

# -----------------------------------------------------------------------------
# Step 4: Encode setup script and prepare user data
# -----------------------------------------------------------------------------

echo_info "Preparing user data..."

# Read the setup script
SETUP_SCRIPT_PATH="../../../os/alpine/setup-vpn.sh"
if [ ! -f "$SETUP_SCRIPT_PATH" ]; then
    echo_error "Setup script not found at: $SETUP_SCRIPT_PATH"
fi

# Encode the setup script to base64
SETUP_SCRIPT_BASE64=$(base64 -w0 "$SETUP_SCRIPT_PATH" 2>/dev/null || base64 "$SETUP_SCRIPT_PATH" | tr -d '\n')

# Encode credentials to base64
ADMIN_PASSWORD_B64=$(echo -n "$ADMIN_PASSWORD" | base64 -w0 2>/dev/null || echo -n "$ADMIN_PASSWORD" | base64 | tr -d '\n')
CLIENT_USERNAME_B64=$(echo -n "$CLIENT_USERNAME" | base64 -w0 2>/dev/null || echo -n "$CLIENT_USERNAME" | base64 | tr -d '\n')
CLIENT_PASSWORD_B64=$(echo -n "$CLIENT_PASSWORD" | base64 -w0 2>/dev/null || echo -n "$CLIENT_PASSWORD" | base64 | tr -d '\n')

# Create user data script
USER_DATA=$(cat <<EOF
#!/bin/sh
set -euo pipefail

# Install base64 decoder
apk add --no-cache coreutils

# Decode credentials
export ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d)
export CLIENT_USERNAME=$(echo "$CLIENT_USERNAME_B64" | base64 -d)
export CLIENT_PASSWORD=$(echo "$CLIENT_PASSWORD_B64" | base64 -d)

# Decode and run setup script
echo "$SETUP_SCRIPT_BASE64" | base64 -d > /tmp/setup-vpn.sh
chmod +x /tmp/setup-vpn.sh
/tmp/setup-vpn.sh
rm /tmp/setup-vpn.sh

# Signal completion
touch /tmp/vpn-setup-complete
EOF
)

# -----------------------------------------------------------------------------
# Step 5: Create the instance (Spot)
# -----------------------------------------------------------------------------

echo_info "Launching Spot instance..."

# Encode user data to base64
USER_DATA_B64=$(echo "$USER_DATA" | base64 -w0 2>/dev/null || echo "$USER_DATA" | base64 | tr -d '\n')

# Launch the instance
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$ALPINE_AMI" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --instance-market-options '{"MarketType": "spot", "SpotOptions": {"SpotInstanceType": "one-time", "InstanceInterruptionBehavior": "terminate"}}' \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":'"$VOLUME_SIZE"',"VolumeType":"'"$VOLUME_TYPE"'","DeleteOnTermination":true}}]' \
    --tag-specifications '{"ResourceType":"instance","Tags":[{"Key":"Name","Value":"'"$INSTANCE_NAME"'"}]}' \
    --user-data "$USER_DATA_B64" \
    --query 'Instances[0].InstanceId' \
    --output text \
    --region "$REGION")

echo_info "Instance launched: $INSTANCE_ID"

# Wait for instance to be running
echo_info "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"

# -----------------------------------------------------------------------------
# Step 6: Allocate Elastic IP
# -----------------------------------------------------------------------------

echo_info "Allocating Elastic IP..."
ALLOCATION_ID=$(aws ec2 allocate-address --domain vpc --region "$REGION" --query 'AllocationId' --output text)
PUBLIC_IP=$(aws ec2 describe-addresses --allocation-ids "$ALLOCATION_ID" --region "$REGION" --query 'Addresses[0].PublicIp' --output text)

echo_info "Elastic IP allocated: $PUBLIC_IP (Allocation ID: $ALLOCATION_ID)"

# Associate Elastic IP with instance
aws ec2 associate-address --instance-id "$INSTANCE_ID" --allocation-id "$ALLOCATION_ID" --region "$REGION"

echo_info "Elastic IP associated with instance."

# -----------------------------------------------------------------------------
# Step 7: Wait for setup to complete
# -----------------------------------------------------------------------------

echo_info "Waiting for VPN setup to complete (this may take 2-3 minutes)..."

# Wait for the setup to complete by checking for a signal file
# Since SSH is disabled, we can't directly check, but we can wait for the instance to be ready
sleep 60

# Try to check if WireGuard port is open
if command -v nc &> /dev/null; then
    MAX_ATTEMPTS=30
    ATTEMPT=0
    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        if nc -z -w 2 "$PUBLIC_IP" "$WG_PORT" 2>/dev/null; then
            echo_info "WireGuard port ${WG_PORT}/udp is open!"
            break
        fi
        sleep 10
        ATTEMPT=$((ATTEMPT + 1))
        echo_info "Waiting for WireGuard port to open... ($ATTEMPT/$MAX_ATTEMPTS)"
    done
else
    echo_info "nc not available, waiting 120 seconds..."
    sleep 120
fi

# -----------------------------------------------------------------------------
# Step 8: Display summary
# -----------------------------------------------------------------------------

echo ""
echo "======================================================================"
echo "AWS Spot Instance Provisioning Complete!"
echo "======================================================================"
echo ""
echo "Instance Details:"
echo "  Instance ID: $INSTANCE_ID"
echo "  Public IP: $PUBLIC_IP"
echo "  Region: $REGION"
echo "  Instance Type: $INSTANCE_TYPE (Spot)"
echo "  Security Group: $SECURITY_GROUP_ID"
echo ""
echo "SSH Key:"
echo "  Key Name: $KEY_NAME"
echo "  Private Key File: ${KEY_NAME}.pem"
echo "  IMPORTANT: Keep this file secure!"
echo ""
echo "Credentials (save these!):"
echo "  Admin Username: admin"
echo "  Admin Password: [the password you entered]"
echo "  Client Username: $CLIENT_USERNAME"
echo "  Client Password: [the password you entered]"
echo ""
echo "WireGuard Configuration:"
echo "  Port: ${WG_PORT}/udp"
echo "  Endpoint: ${PUBLIC_IP}:${WG_PORT}"
echo ""
echo "Client Configuration:"
echo "  The client config file is generated on the server at:"
echo "    /etc/wireguard/clients/${CLIENT_USERNAME}.conf"
echo "    /etc/wireguard/clients/${CLIENT_USERNAME}-full.conf (with credentials)"
echo ""
echo "  To retrieve the client config file:"
echo "    1. Temporarily add SSH access to the security group:"
echo "       aws ec2 authorize-security-group-ingress \\"
echo "         --group-id $SECURITY_GROUP_ID \\"
echo "         --protocol tcp --port 22 --cidr YOUR_IP/32 --region $REGION"
echo "    2. SSH to the instance: ssh -i ${KEY_NAME}.pem admin@${PUBLIC_IP}"
echo "    3. Get the config: cat /etc/wireguard/clients/${CLIENT_USERNAME}-full.conf"
echo "    4. Remove SSH access:"
echo "       aws ec2 revoke-security-group-ingress \\"
echo "         --group-id $SECURITY_GROUP_ID \\"
echo "         --protocol tcp --port 22 --cidr YOUR_IP/32 --region $REGION"
echo ""
echo "Cost Estimate:"
echo "  Instance (Spot t4g.nano): ~\$0.0014/hour (varies by region)"
echo "  EBS Volume (5GB gp2): ~\$0.50/month"
echo "  Elastic IP: Free (while attached to running instance)"
echo ""
echo "To terminate the instance and clean up:"
echo "  aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION"
echo "  aws ec2 release-address --allocation-id $ALLOCATION_ID --region $REGION"
echo "  aws ec2 delete-security-group --group-id $SECURITY_GROUP_ID --region $REGION"
echo "  aws ec2 delete-key-pair --key-name $KEY_NAME --region $REGION"
echo ""
echo "======================================================================"
