#!/usr/bin/env bash
# First-time setup for the Caravan Pi 5.
# Run as the pi user: curl -sSL .../setup.sh | bash
set -euo pipefail

REPO_URL="https://github.com/schmidu-co/caravan-lab.git"
LAB_DIR="/opt/caravan-lab"

echo "=== [1/9] System update ==="
sudo apt-get update -qq && sudo apt-get upgrade -y -qq

echo "=== [2/9] Enable I2C, SPI, Camera ==="
sudo raspi-config nonint do_i2c 0    # enable I2C (BME280 + Grove HAT ADC)
sudo raspi-config nonint do_spi 0    # enable SPI
sudo raspi-config nonint do_camera 0 # enable camera interface (Phase 2)
# GPS uses USB G-Mouse (/dev/ttyUSB0) — no UART config needed

echo "=== [3/9] Blacklist DVB kernel modules (RTL-SDR) ==="
sudo tee /etc/modprobe.d/blacklist-dvb.conf > /dev/null << 'EOF'
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2830
EOF
sudo update-initramfs -u -k all 2>/dev/null || true

echo "=== [4/9] Install Docker ==="
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
else
  echo "Docker already installed, skipping"
fi

echo "=== [5/9] Add pi to groups ==="
CURRENT_USER="${SUDO_USER:-${USER:-pi}}"
for grp in docker i2c dialout gpio; do
  sudo usermod -aG "$grp" "$CURRENT_USER" 2>/dev/null || true
done

echo "=== [6/9] Install Tailscale ==="
if ! command -v tailscale &>/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
else
  echo "Tailscale already installed, skipping"
fi

echo "=== [7/9] Firewall (UFW) ==="
sudo apt-get install -y -qq ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp  comment 'SSH'
sudo ufw allow 41641/udp comment 'Tailscale'
sudo ufw --force enable

echo "=== [8/9] Create Docker network and clone repo ==="
docker network create caravan 2>/dev/null || echo "Network 'caravan' already exists"

if [[ -d "$LAB_DIR/.git" ]]; then
  echo "Repo already cloned at $LAB_DIR, pulling latest"
  sudo git -C "$LAB_DIR" pull --ff-only
else
  sudo git clone "$REPO_URL" "$LAB_DIR"
fi

sudo chown -R "${CURRENT_USER}:${CURRENT_USER}" "$LAB_DIR"
sudo chmod +x "$LAB_DIR/scripts/"*.sh

echo "=== [9/9] Install systemd deploy timer ==="
sudo cp "$LAB_DIR/scripts/caravan-deploy.service" /etc/systemd/system/
sudo cp "$LAB_DIR/scripts/caravan-deploy.timer"   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now caravan-deploy.timer

echo ""
echo "================================================================"
echo " Setup complete."
echo ""
echo " IMPORTANT — SSH key setup (do this now, before closing session):"
echo "   On your local machine:"
echo "     ssh-keygen -t ed25519 -C 'caravan-pi'"
echo "     ssh-copy-id -i ~/.ssh/id_ed25519.pub ${CURRENT_USER}@caravan.local"
echo "   Then disable password login on the Pi:"
echo "     sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config"
echo "     sudo systemctl restart sshd"
echo ""
echo " Next steps:"
echo "   1. Log out and back in (group memberships)"
echo "   2. sudo tailscale up --authkey <TS_AUTHKEY>"
echo "   3. cd $LAB_DIR && cp .env.example .env && nano .env"
echo "   4. Follow the Quickstart in README.md"
echo "================================================================"
