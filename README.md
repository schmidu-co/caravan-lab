# caravan-lab

**Ops / infrastructure repo** for the Caravan Telemetry project.

## Two-repo architecture

| Repo | What lives here | Who touches it |
|------|-----------------|----------------|
| **[caravan](https://github.com/schmidu-co/caravan)** | Next.js app, Python workers, Dockerfiles, GitHub Actions CI | Developers — write code, push images to GHCR |
| **[caravan-lab](https://github.com/schmidu-co/caravan-lab)** ← you are here | Docker Compose stacks, deploy scripts, Mosquitto config, `.env.example` | Ops — runs on the Raspberry Pi 5 in the caravan |

> **"lab" = home lab, not test environment.**  
> There is only one running environment: the Pi in the caravan. `caravan-lab` is the deployment/ops repo for that system, not a staging or test environment.

Images are built in `caravan` by GitHub Actions and pushed to GHCR (`ghcr.io/schmidu-co/*`).  
`caravan-lab` pulls those images and runs them — no code is built here.

## What this is

A Raspberry Pi 5 in a caravan collects sensor data and makes it accessible remotely — without a public IP (CGNAT mobile router):

- **ADS-B** aircraft sightings via RTL-SDR USB dongle
- **GPS** position via USB G-Mouse RoHS IPX6 (USB serial)
- **Sensors** temperature / humidity / pressure (Grove BME280, I2C) and gas/smoke (Grove MQ2, analog)
- **Camera** optional MJPEG stream via Pi Camera Module 3 *(Phase 2)*

Data flow:

```
Hardware → Python workers → Mosquitto (MQTT) → Next.js web app → TimescaleDB
                                                    ↑
                             Cloudflare Tunnel (public HTTPS, CGNAT-safe)
                             Tailscale (SSH / admin, CGNAT-safe)
```

## Hardware

| Component | Model | Interface |
|-----------|-------|-----------|
| Pi | Raspberry Pi 5, 16 GB RAM | — |
| Cooling | Official active cooler | — |
| Storage | Kingston NVMe 1 TB + M.2 HAT | PCIe |
| Adapter board | Seeed Grove Base HAT for RPi (SKU 103030275) | GPIO 40-pin |
| ADS-B | RTL-SDR v3/v4 or Nooelec NESDR SMArt | USB |
| ADS-B antenna | FlightAware 1090 MHz or DIY cantenna | SMA |
| GPS | USB G-Mouse RoHS IPX6 | USB |
| Gas | Grove MQ2 | Analog A0 (Grove HAT ADC) |
| Temp / Humidity / Pressure | Grove BME280 | I2C (Grove) |
| Camera *(Phase 2)* | Pi Camera Module 3 | CSI |

> **Router:** TCL MW12VK-2AL-CCH1 with Swisscom SIM. Mobile routers are typically behind CGNAT — hence Tailscale + Cloudflare Tunnel for remote access.
>
> **Power:** Pi 5 + NVMe + RTL-SDR + active fan draws 12–18 W under load.  
> Use the official Pi 5 PSU (5.1 V / 5 A) or a quality 12 V → 5 V / 5 A DC-DC converter from the caravan 12 V bus.

## Stack overview

| Stack | Container(s) | Purpose |
|-------|-------------|---------|
| `tailscale` | tailscale | VPN – SSH / admin (CGNAT-safe) |
| `cloudflared` | cloudflared | Cloudflare Tunnel – Web UI on :443 |
| `mqtt` | mosquitto | Message bus between workers and web app |
| `caravan` | caravan-web, caravan-db | Next.js 15 app + TimescaleDB |
| `adsb` | ultrafeeder | RTL-SDR → readsb (wiedehopf) + tar1090 map |
| `gpsd` | caravan-gpsd-bridge | USB GPS → gpsd:2947 + MQTT (live position → tar1090) |
| `sensors` | caravan-sensors | Grove BME280 + MQ2 → MQTT |
| `camera` | caravan-camera | Pi Cam MJPEG stream *(Phase 2)* |

## MQTT topic schema

All payloads are JSON. `ts` is ISO 8601 UTC.

| Topic | Payload |
|-------|---------|
| `caravan/gps/position` | `lat`, `lon`, `alt_m`, `speed_kmh`, `heading`, `ts` |
| `caravan/sensors/bme280` | `temp_c`, `humidity_pct`, `pressure_hpa`, `ts` |
| `caravan/sensors/mq2` | `raw_adc`, `ppm_approx`, `alarm`, `ts` |
| `caravan/adsb/aircraft` | `icao`, `callsign`, `lat`, `lon`, `alt_ft`, `speed_kts`, `ts` |

## Quickstart

### 1. Flash Raspberry Pi OS

Download **Raspberry Pi OS Bookworm Lite (64-bit)** and flash with Raspberry Pi Imager.  
In Imager Advanced Options: enable SSH, set hostname to `caravan`, configure Wi-Fi if needed.

### 2. First boot — run setup script

```bash
ssh pi@caravan.local
curl -sSL https://raw.githubusercontent.com/schmidu-co/caravan-lab/main/scripts/setup.sh | bash
```

The setup script:
- Enables I2C and SPI via `raspi-config`
- Blacklists DVB kernel modules so RTL-SDR works
- Installs Docker (via get.docker.com)
- Adds the `pi` user to the `docker`, `i2c`, `dialout`, and `gpio` groups
- Installs Tailscale
- Creates the shared Docker network `caravan`
- Clones this repo to `/opt/caravan-lab`
- Installs and enables the systemd deploy timer

After the script finishes, **log out and back in** for group memberships to take effect, then authenticate Tailscale:

```bash
sudo tailscale up --authkey <TS_AUTHKEY>
```

### 3. Configure environment

```bash
cd /opt/caravan-lab
cp .env.example .env
nano .env   # fill in all required values
```

Required variables: `TAILSCALE_AUTHKEY`, `TUNNEL_TOKEN`, `POSTGRES_PASSWORD`, `NEXTAUTH_SECRET`, `NEXTAUTH_URL`, `FEEDER_LAT`, `FEEDER_LON`, `FEEDER_ALT_M`.

`GPS_DEVICE` defaults to `/dev/ttyUSB0`. If the G-Mouse appears as `/dev/ttyACM0`, set it here.

### 4. Start stacks (in order)

```bash
cd /opt/caravan-lab

# 1. Infrastructure
docker compose -f stacks/tailscale/docker-compose.yml --env-file .env up -d
docker compose -f stacks/mqtt/docker-compose.yml      --env-file .env up -d

# 2. App + database
docker compose -f stacks/caravan/docker-compose.yml   --env-file .env up -d

# 3. Run DB migrations (first time only)
docker exec caravan-web npx prisma migrate deploy

# 4. Workers — gpsd must start before adsb (ultrafeeder reads live position from gpsd)
docker compose -f stacks/gpsd/docker-compose.yml      --env-file .env up -d
docker compose -f stacks/adsb/docker-compose.yml      --env-file .env up -d
docker compose -f stacks/sensors/docker-compose.yml   --env-file .env up -d

# 5. Public tunnel (after web is healthy)
docker compose -f stacks/cloudflared/docker-compose.yml --env-file .env up -d
```

### 5. Verify

| URL | What you see |
|-----|-------------|
| `http://caravan.local:3000` | Caravan web UI (local network) |
| `http://caravan.local:8080` | tar1090 ADS-B map |
| `https://your.domain.com` | Caravan web UI via Cloudflare Tunnel |

Check live MQTT traffic:

```bash
docker exec -it mqtt mosquitto_sub -t 'caravan/#' -v
```

## Live caravan position in the ADS-B map

The `gpsd` stack runs a gpsd daemon on port 2947. The `adsb` stack connects readsb to it via `READSB_GPSD_HOST`. This means:

- readsb continuously reads the live GPS fix from gpsd
- tar1090 displays the updated receiver position in real time (blue dot + range rings)
- No restart required as the caravan moves — the marker follows automatically

The static `FEEDER_LAT`/`FEEDER_LON` in `.env` are only used as the initial map center and as a fallback before the first GPS fix.

## App — macOS, Windows, iPhone

The caravan web app is built as a **Progressive Web App (PWA)**. No app store needed.

| Platform | How to install |
|----------|---------------|
| iPhone | Safari → Share → "Add to Home Screen" |
| macOS | Safari or Chrome → install banner / address bar icon |
| Windows | Edge or Chrome → install banner / address bar icon |

The PWA works offline for the last-cached dashboard view. Live data requires connectivity.

Native app wrappers (Phase 2, optional): **Capacitor** (iOS/Android from the same Next.js codebase) or **Tauri** (macOS/Windows desktop).

## Automatic deploy

The systemd timer runs `scripts/deploy.sh` every 15 minutes. It pulls updated images and restarts only changed stacks.

```bash
# Manual trigger
sudo systemctl start caravan-deploy.service

# Watch logs
journalctl -u caravan-deploy -f
```

## Repository layout

```
caravan-lab/
├── .env.example
├── stacks/
│   ├── tailscale/
│   │   └── docker-compose.yml
│   ├── cloudflared/
│   │   └── docker-compose.yml
│   ├── mqtt/
│   │   ├── docker-compose.yml
│   │   └── config/mosquitto.conf
│   ├── caravan/
│   │   └── docker-compose.yml
│   ├── adsb/
│   │   └── docker-compose.yml
│   ├── gpsd/
│   │   └── docker-compose.yml
│   ├── sensors/
│   │   └── docker-compose.yml
│   └── camera/              # Phase 2
│       └── docker-compose.yml
└── scripts/
    ├── setup.sh                 # First-time Pi setup
    ├── deploy.sh                # Smart image-pull + restart
    ├── caravan-deploy.service   # systemd service unit
    └── caravan-deploy.timer     # systemd timer (every 15 min)
```
