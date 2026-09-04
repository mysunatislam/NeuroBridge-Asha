#!/usr/bin/env bash
# ==============================================================================
# NeuroBridge Asha / FingerSpeak - Raspberry Pi Automated Edge Setup
# Supported: Raspberry Pi OS (Bookworm 64-bit) on Raspberry Pi 4 / 5
# ==============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BLUE}${BOLD}======================================================${NC}"
echo -e "${BLUE}${BOLD}   NeuroBridge Asha - Raspberry Pi Edge Setup        ${NC}"
echo -e "${BLUE}${BOLD}======================================================${NC}"

# 1. Root / Sudo Check
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}Notice: This script requires administrative privileges to configure system services.${NC}"
    echo -e "Re-running with sudo..."
    exec sudo bash "$0" "$@"
fi

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo -e "\n${GREEN}[1/6] Inspecting system and hardware...${NC}"
ARCH=$(uname -m)
echo "Architecture: $ARCH"
if [[ "$ARCH" != "aarch64" && "$ARCH" != "armv7l" ]]; then
    echo -e "${YELLOW}Warning: Non-ARM architecture detected ($ARCH). Proceeding in test/simulation mode.${NC}"
fi

if [ -f /proc/device-tree/model ]; then
    PI_MODEL=$(tr -d '\0' < /proc/device-tree/model)
    echo "Device Model: $PI_MODEL"
else
    echo "Device Model: Generic Linux Host"
fi

# 2. Install Native Operating System Packages
echo -e "\n${GREEN}[2/6] Installing OS dependencies and Picamera2...${NC}"
apt-get update
apt-get install -y --no-install-recommends \
    python3-picamera2 \
    python3-venv \
    python3-pip \
    libcamera-apps \
    v4l-utils \
    git \
    curl

# 3. Setup Python Virtual Environment
echo -e "\n${GREEN}[3/6] Setting up Python virtual environment with system site-packages...${NC}"
INSTALL_DIR="/opt/fingerspeak"
mkdir -p "$INSTALL_DIR"

if [ "$REPO_ROOT" != "$INSTALL_DIR" ]; then
    echo "Copying edge package to $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR/services"
    cp -r "$REPO_ROOT/services/edge" "$INSTALL_DIR/services/"
fi

VENV_PATH="$INSTALL_DIR/.venv"
if [ ! -d "$VENV_PATH" ]; then
    python3 -m venv --system-site-packages "$VENV_PATH"
fi

echo "Installing edge service in editable mode..."
"$VENV_PATH/bin/pip" install --upgrade pip
"$VENV_PATH/bin/pip" install -e "$INSTALL_DIR/services/edge"

# 4. Provision Secure Pairing Credentials
echo -e "\n${GREEN}[4/6] Configuring security and credentials...${NC}"
CREDENTIAL_DIR="/var/lib/fingerspeak"
ENV_DIR="/etc/fingerspeak"
mkdir -p "$CREDENTIAL_DIR" "$ENV_DIR"
chmod 0700 "$CREDENTIAL_DIR" "$ENV_DIR"

ENV_FILE="$ENV_DIR/edge.env"
if [ ! -f "$ENV_FILE" ]; then
    # Generate 24 random alphanumeric characters
    GENERATED_CODE=$("$VENV_PATH/bin/python" -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(24)))")
    cat <<EOF > "$ENV_FILE"
# NeuroBridge Asha Edge Configuration
FINGERSPEAK_EDGE_PAIRING_CODE=$GENERATED_CODE
FINGERSPEAK_EDGE_CREDENTIAL_STORE=$CREDENTIAL_DIR/device-credential.json
FINGERSPEAK_EDGE_ADAPTER=picamera2
FINGERSPEAK_EDGE_HOST=0.0.0.0
FINGERSPEAK_EDGE_PORT=8765
EOF
    chmod 0600 "$ENV_FILE"
    echo "Created fresh configuration at $ENV_FILE"
fi

chown -R "$TARGET_USER:$TARGET_USER" "$INSTALL_DIR" "$CREDENTIAL_DIR" "$ENV_DIR"

# 5. Setup Systemd Service
echo -e "\n${GREEN}[5/6] Registering fingerspeak-edge systemd service...${NC}"
SERVICE_FILE="/etc/systemd/system/fingerspeak-edge.service"
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=FingerSpeak Raspberry Pi Edge Bridge
After=network.target network-online.target

[Service]
Type=simple
User=$TARGET_USER
Group=$TARGET_USER
WorkingDirectory=$INSTALL_DIR/services/edge
EnvironmentFile=$ENV_FILE
ExecStart=$VENV_PATH/bin/python -m fingerspeak_edge --adapter \${FINGERSPEAK_EDGE_ADAPTER} --host \${FINGERSPEAK_EDGE_HOST} --port \${FINGERSPEAK_EDGE_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable fingerspeak-edge.service
systemctl restart fingerspeak-edge.service

# 6. Verify Service & Network
echo -e "\n${GREEN}[6/6] Verifying service readiness and network address...${NC}"
sleep 2

PAIRING_CODE=$(grep -E '^FINGERSPEAK_EDGE_PAIRING_CODE=' "$ENV_FILE" | cut -d= -f2)
PORT=$(grep -E '^FINGERSPEAK_EDGE_PORT=' "$ENV_FILE" | cut -d= -f2 || echo "8765")
PORT="${PORT:-8765}"

# Determine primary IP address
IP_LIST=$(hostname -I 2>/dev/null || ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' || true)
PRIMARY_IP=$(echo "$IP_LIST" | awk '{print $1}')
PRIMARY_IP="${PRIMARY_IP:-<RASPBERRY_PI_IP>}"

echo -e "\n${BLUE}${BOLD}======================================================${NC}"
echo -e "${GREEN}${BOLD}   Raspberry Pi Edge Bridge Successfully Installed!   ${NC}"
echo -e "${BLUE}${BOLD}======================================================${NC}"
echo -e "Service Status : $(systemctl is-active fingerspeak-edge.service || echo 'inactive')"
echo -e "Local IP(s)    : ${BOLD}${IP_LIST:-None}${NC}"
echo -e ""
echo -e "${YELLOW}${BOLD}MOBILE APP CONNECTION DETAILS:${NC}"
echo -e "1. Open ${BOLD}NeuroBridge Asha${NC} on your phone (Android or iOS)."
echo -e "2. Navigate to ${BOLD}Setup & Settings${NC} -> ${BOLD}Pair Wheelchair Raspberry Pi${NC}."
echo -e "3. Set ${BOLD}Pi WebSocket URL${NC} to:"
echo -e "   ${GREEN}${BOLD}ws://${PRIMARY_IP}:${PORT}/v1/device/ws${NC}"
echo -e "4. Enter the ${BOLD}One-time Pi Pairing Code${NC}:"
echo -e "   ${GREEN}${BOLD}${PAIRING_CODE}${NC}"
echo -e "5. Tap ${BOLD}Pair Wheelchair Unit${NC}."
echo -e "${BLUE}${BOLD}======================================================${NC}"
echo -e "To view live logs: ${BOLD}journalctl -u fingerspeak-edge -f${NC}"
echo -e "To restart service: ${BOLD}sudo systemctl restart fingerspeak-edge${NC}"
echo -e "${BLUE}${BOLD}======================================================${NC}\n"
