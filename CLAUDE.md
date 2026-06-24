# CLAUDE.md — caravan-lab

## What this repo is

This is the **ops/infrastructure repo** for the Caravan Telemetry project.  
It contains only Docker Compose stacks, deploy scripts, Mosquitto config, and `.env.example`.

App code, Python workers, and all Dockerfiles live in **[schmidu/caravan](https://github.com/schmidu/caravan)**.

## Companion repo — caravan

The `caravan` repo builds and publishes these images to GHCR:

| Image | Source |
|-------|--------|
| `ghcr.io/schmidu-co/caravan-web:latest` | Next.js 15, App Router, Prisma, NextAuth v5, Tailwind v4 |
| `ghcr.io/schmidu-co/caravan-gpsd-bridge:latest` | Python — runs gpsd on :2947, reads USB G-Mouse, publishes MQTT |
| `ghcr.io/schmidu-co/caravan-sensors:latest` | Python — reads BME280 + MQ2 via Grove HAT, publishes MQTT |
| `ghcr.io/schmidu-co/caravan-camera:latest` | Python — picamera2 MJPEG stream *(Phase 2)* |

## Architecture decisions

| Area | Decision | Reason |
|------|----------|--------|
| Remote access | Tailscale + Cloudflare Tunnel | CGNAT-safe; Pi has no public IP |
| No Traefik | Cloudflare Tunnel routes directly to `caravan-web:3000` | Single web app; extra reverse proxy is pure overhead |
| MQTT broker | Mosquitto 2.0 | Three independent producers (GPS, sensors, ADS-B) justify a message bus |
| Database | `timescale/timescaledb:latest-pg16` | Native time-series hypertables; Prisma knows PostgreSQL |
| GPIO | lgpio / libgpiod v2 | `RPi.GPIO` is dead on Pi 5 — do not use it |
| ADS-B | `ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:latest` | Built on wiedehopf/readsb + wiedehopf/tar1090; all-in-one |
| Camera | picamera2 + JpegEncoder | Pi 5 removed the HW MJPEG encoder |
| Grove ADC | Onboard STM32 at I2C `0x04` | No external ADS1115/MCP3008 needed for MQ2 |

## Stack startup order

Stacks must be started in this order on first boot. The deploy timer maintains the correct running state thereafter.

1. `tailscale` — always first (SSH access if anything breaks)
2. `mqtt` — before any workers or the web app
3. `caravan` (db + web)
4. `gpsd` — before adsb (ultrafeeder connects to gpsd for live receiver position)
5. `adsb`, `sensors` — after gpsd
6. `cloudflared` — after caravan-web is healthy

## Hardware context

**Router:** TCL MW12VK-2AL-CCH1 with Swisscom SIM — CGNAT, no public IP. Remote access via Tailscale + Cloudflare Tunnel only.

**Grove Base HAT for RPi** (SKU 103030275)

| Device | I2C address / path | Notes |
|--------|--------------------|-------|
| Onboard ADC (STM32) | `0x04` | 12-bit, 4 analog channels |
| MQ2 gas sensor | A0 → ADC channel 0 | Raw 0–4095; higher = more gas |
| BME280 | `0x76` on I2C bus 1 | Temp / humidity / pressure |
| USB G-Mouse GPS | `/dev/ttyUSB0` (or `/dev/ttyACM0`) | USB serial; set via `GPS_DEVICE` env var |
| RTL-SDR dongle | `/dev/bus/usb` | USB; DVB modules must be blacklisted |
| Pi Camera | `/dev/video0`, `/dev/media*` | CSI; Phase 2 only |

**GPS → tar1090 live position:**  
gpsd-bridge runs gpsd on port 2947. ultrafeeder connects via `READSB_GPSD_HOST=caravan-gpsd-bridge`. readsb reads the live GPS fix and updates its receiver lat/lon continuously — the blue dot and range rings in tar1090 follow the caravan as it drives.

**Client apps (caravan repo):**  
The Next.js web app must be a PWA (Progressive Web App) — installable on iPhone (Safari), macOS and Windows (Chrome/Edge/Safari) without an app store. Add `next-pwa` and a web app manifest with appropriate icons. Native wrappers (Capacitor for iOS, Tauri for desktop) are Phase 2.

## MQTT topics (for reference when editing compose env vars)

```
caravan/gps/position      {"lat", "lon", "alt_m", "speed_kmh", "heading", "ts"}
caravan/sensors/bme280    {"temp_c", "humidity_pct", "pressure_hpa", "ts"}
caravan/sensors/mq2       {"raw_adc", "ppm_approx", "alarm", "ts"}
caravan/adsb/aircraft     {"icao", "callsign", "lat", "lon", "alt_ft", "speed_kts", "ts"}
```

All `ts` values are ISO 8601 UTC strings.

## Common tasks

### Add a new stack
1. Create `stacks/<name>/docker-compose.yml`
2. Add `<name>` to the `STACKS` array in `scripts/deploy.sh`
3. Document new env vars in `.env.example`

### Add a new environment variable
1. Add to `.env.example` with a comment and a safe placeholder value
2. Reference it in the relevant `docker-compose.yml` under `environment:`

### Update Mosquitto config
Edit `stacks/mqtt/config/mosquitto.conf`, then:
```bash
docker compose -f stacks/mqtt/docker-compose.yml restart
```

### Check what a stack is doing
```bash
docker compose -f stacks/<name>/docker-compose.yml logs -f
```

### Force a redeploy of one stack
```bash
docker compose -f stacks/<name>/docker-compose.yml --env-file .env pull
docker compose -f stacks/<name>/docker-compose.yml --env-file .env up -d
```

## What NOT to do

- Do not put application code or Dockerfiles in this repo — they belong in `caravan`
- Do not add Traefik — Cloudflare Tunnel handles ingress
- Do not build Docker images here — images are built by CI in `caravan` and pushed to GHCR
- Do not use `RPi.GPIO` anywhere — it does not work on Pi 5
- Do not commit `.env` — only `.env.example` is tracked by git
- Do not expose Mosquitto on a public port — it runs unauthenticated on the internal `caravan` network
