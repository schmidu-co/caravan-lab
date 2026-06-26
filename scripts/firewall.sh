#!/usr/bin/env bash
# Caravan Pi — UFW Firewall Setup
# Standalone script; also called by setup.sh on first boot.
# Safe to re-run (UFW rules are idempotent).
set -euo pipefail

echo "=== Firewall (UFW) ==="

if ! command -v ufw &>/dev/null; then
  sudo apt-get install -y -qq ufw
fi

# Default: deny all incoming, allow all outgoing
sudo ufw default deny incoming
sudo ufw default allow outgoing

# SSH — allow from anywhere (Tailscale provides the outer security layer)
sudo ufw allow 22/tcp  comment 'SSH'

# Tailscale — UDP port for WireGuard
sudo ufw allow 41641/udp comment 'Tailscale'

# NOTE: Docker bypasses UFW by directly manipulating iptables.
# All Docker container ports are therefore bound to 127.0.0.1 in docker-compose.yml
# so they are not reachable from outside even without UFW rules.
# External access is via Tailscale (SSH / admin) or Cloudflare Tunnel (HTTPS only).

sudo ufw --force enable
sudo ufw status verbose

echo "Firewall active."
