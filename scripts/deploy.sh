#!/usr/bin/env bash
# Smart deploy: pulls updated images and restarts only changed stacks.
# Runs every 15 min via caravan-deploy.timer.
set -euo pipefail

LAB_DIR="${CARAVAN_LAB_DIR:-/opt/caravan-lab}"
ENV_FILE="$LAB_DIR/.env"
LOG_FILE="/var/log/caravan-deploy.log"

# Ordered list of stacks to check. tailscale and cloudflared are excluded:
# Tailscale updates via its own mechanism; cloudflared is rarely changed.
STACKS=(mqtt caravan gpsd adsb sensors)  # gpsd before adsb: ultrafeeder needs gpsd running

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

# Load env vars so GHCR_USER / GHCR_TOKEN are available in this shell
# shellcheck source=/dev/null
set -a; source "$ENV_FILE" 2>/dev/null || true; set +a

# Login to GHCR before pulling — required for private images
if [[ -n "${GHCR_TOKEN:-}" && -n "${GHCR_USER:-}" ]]; then
  if echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin --quiet 2>&1; then
    log "GHCR login OK ($GHCR_USER)"
  else
    log "WARN GHCR login failed — pulls of private images may fail"
  fi
else
  log "WARN GHCR_TOKEN / GHCR_USER not set in .env — skipping login"
fi

# Returns sorted SHA256 IDs of all images declared in a compose file.
# Used to detect whether a pull brought in new image layers.
get_image_ids() {
  local dir="$1"
  docker compose -f "$dir/docker-compose.yml" --env-file "$ENV_FILE" config --images 2>/dev/null \
    | while IFS= read -r img; do
        docker image inspect "$img" --format '{{.Id}}' 2>/dev/null || true
      done \
    | sort | paste -sd,
}

deploy_stack() {
  local stack="$1"
  local dir="$LAB_DIR/stacks/$stack"

  if [[ ! -f "$dir/docker-compose.yml" ]]; then
    log "SKIP $stack (no docker-compose.yml)"
    return
  fi

  local before
  before=$(get_image_ids "$dir")

  # Pull quietly; suppress benign errors (e.g. image not on registry yet)
  docker compose -f "$dir/docker-compose.yml" --env-file "$ENV_FILE" pull --quiet 2>&1 || true

  local after
  after=$(get_image_ids "$dir")

  if [[ "$before" != "$after" ]]; then
    log "UPDATE $stack — new image(s), restarting"
    docker compose -f "$dir/docker-compose.yml" --env-file "$ENV_FILE" up -d --remove-orphans
    log "DONE $stack"
  else
    log "OK $stack (up to date)"
  fi
}

log "=== deploy started ==="
for stack in "${STACKS[@]}"; do
  deploy_stack "$stack" || log "ERROR in $stack (see above)"
done
log "=== deploy complete ==="
