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

Download and install **[Raspberry Pi Imager](https://www.raspberrypi.com/software/)** (Windows / macOS / Linux).

**OS auswählen:**

```
Choose OS
  └── Raspberry Pi OS (other)
        └── Raspberry Pi OS Lite (64-bit)   ← diese Option wählen
```

> "Lite" = kein Desktop, weniger RAM-Verbrauch — alles läuft in Docker.  
> Die aktuelle Version ist automatisch Debian Bookworm (Debian 12). Die 64-bit-Variante ist Pflicht für den Pi 5.

**Vor dem Flashen: Advanced Options öffnen** (`Ctrl+Shift+X` oder Zahnrad-Icon):

| Einstellung | Wert |
|-------------|------|
| Hostname | `caravan` |
| SSH aktivieren | ✓ (Passwort-Authentifizierung) |
| Benutzername | `idefix` |
| Passwort | sicheres Passwort setzen |
| WLAN | nur wenn kein LAN-Kabel beim ersten Boot |
| Locale | Zeitzone + Tastaturlayout nach Bedarf |

SD-Karte / NVMe flashen, in den Pi einlegen, booten.

### 2. SSH-Schlüssel vorbereiten (vor dem ersten Login)

SSH-Schlüssel sind sicherer als Passwörter: Ein mathematisches Schlüsselpaar ersetzt das Passwort.  
Der **private Schlüssel** bleibt auf deinem Rechner, der **öffentliche Schlüssel** wird auf den Pi kopiert.  
Nur wer den passenden privaten Schlüssel besitzt, kann sich einloggen.

#### Schritt 1 — Prüfen ob bereits ein Schlüssel vorhanden ist

**macOS / Linux** (Terminal):
```bash
ls ~/.ssh/id_ed25519.pub
```

**Windows** (PowerShell):
```powershell
Test-Path "$env:USERPROFILE\.ssh\id_ed25519.pub"
```

Wenn die Datei existiert → weiter zu Schritt 2.  
Wenn nicht → neuen Schlüssel generieren:

**macOS / Linux:**
```bash
ssh-keygen -t ed25519 -C "caravan-idefix"
# Speicherort: Enter (Standard ~/.ssh/id_ed25519 übernehmen)
# Passphrase: optional — leer lassen für passwortlosen Zugriff,
#             oder eine Passphrase setzen für zusätzlichen Schutz
```

**Windows** (PowerShell oder Windows Terminal):
```powershell
ssh-keygen -t ed25519 -C "caravan-idefix"
# Speicherort: Enter (Standard C:\Users\<Name>\.ssh\id_ed25519 übernehmen)
# Passphrase: wie oben
```

> Es werden zwei Dateien erstellt:  
> `id_ed25519` — **privater Schlüssel** (niemals weitergeben, niemals committen)  
> `id_ed25519.pub` — **öffentlicher Schlüssel** (wird auf den Pi kopiert)

#### Schritt 2 — Öffentlichen Schlüssel auf den Pi kopieren

Der Pi muss eingeschaltet und im gleichen Netzwerk sein. Passwort-Login muss noch aktiv sein.

**macOS / Linux:**
```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub idefix@caravan.local
# Passwort des Pi-Users eingeben (einmalig)
```

**Windows** (kein `ssh-copy-id` verfügbar — manuell):
```powershell
# Inhalt des öffentlichen Schlüssels anzeigen und kopieren:
Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub"

# Dann auf dem Pi einloggen (noch mit Passwort):
ssh idefix@caravan.local

# Auf dem Pi: Schlüssel eintragen
mkdir -p ~/.ssh
chmod 700 ~/.ssh
echo "HIER_DEN_KOPIERTEN_SCHLUESSEL_EINFUEGEN" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
exit
```

#### Schritt 3 — Schlüssel-Login testen

```bash
ssh idefix@caravan.local
# Muss ohne Passwort funktionieren
```

Wenn der Login klappt: ✓ weiter zu Schritt 4.  
Wenn nicht: Schlüssel prüfen mit `ssh -v idefix@caravan.local` (verbose, zeigt was schiefläuft).

#### Schritt 4 — Passwort-Login deaktivieren

> ⚠️ Erst ausführen wenn Schritt 3 erfolgreich war — sonst sperrt man sich aus.

```bash
# Auf dem Pi (per SSH eingeloggt):
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

Verifizieren — neues Terminal öffnen und testen:
```bash
ssh idefix@caravan.local   # muss weiterhin funktionieren (per Schlüssel)
ssh -o PasswordAuthentication=no idefix@caravan.local  # sollte klappen
```

Versuch mit Passwort — muss jetzt abgelehnt werden:
```bash
ssh -o PubkeyAuthentication=no idefix@caravan.local
# Erwartet: "Permission denied (publickey)"
```

#### Weiterer Zugriff via Tailscale

Sobald Tailscale eingerichtet ist, lautet der SSH-Befehl von überall:
```bash
ssh idefix@caravan          # Tailscale-Hostname (gesetzt in Imager: "caravan")
# oder
ssh idefix@<tailscale-ip>   # IP aus dem Tailscale-Dashboard
```

Auf einem neuen Gerät Zugriff hinzufügen:
```bash
# Neuen öffentlichen Schlüssel auf dem Pi eintragen:
echo "OEFFENTLICHER_SCHLUESSEL_NEUES_GERAET" >> ~/.ssh/authorized_keys
```

### 3. First boot — run setup script

```bash
ssh idefix@caravan.local
```

**Option A — direkter curl-Befehl** (Repo muss öffentlich sein):
```bash
curl -sSL https://raw.githubusercontent.com/schmidu-co/caravan-lab/main/scripts/setup.sh | bash
```

**Option B — via git clone** (funktioniert auch bei privatem Repo):
```bash
sudo git clone https://github.com/schmidu-co/caravan-lab.git /opt/caravan-lab
bash /opt/caravan-lab/scripts/setup.sh
```

Das Setup-Script erledigt:
- I2C und SPI aktivieren (`raspi-config`)
- DVB-Kernel-Module blacklisten (für RTL-SDR)
- Docker installieren (get.docker.com)
- `idefix`-User zu Gruppen hinzufügen: `docker`, `i2c`, `dialout`, `gpio`
- Tailscale installieren
- **UFW Firewall** einrichten (erlaubt nur SSH + Tailscale)
- Docker-Netzwerk `caravan` erstellen
- Repo nach `/opt/caravan-lab` klonen
- systemd Deploy-Timer installieren und aktivieren

Nach dem Script: **ausloggen und neu einloggen** (Gruppenmitgliedschaften), dann Tailscale verbinden:

Auth-Key generieren: **[login.tailscale.com](https://login.tailscale.com) → Settings → Keys → Generate auth key** (preauthorized: ja)

```bash
# tskey-auth-... durch deinen echten Key ersetzen:
sudo tailscale up --authkey tskey-auth-xxxxxxxxxxxxxxxx-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### 4. Configure environment

```bash
cd /opt/caravan-lab
cp .env.example .env
nano .env   # fill in all required values
```

Required variables: `TAILSCALE_AUTHKEY`, `TUNNEL_TOKEN`, `POSTGRES_PASSWORD`, `NEXTAUTH_SECRET`, `NEXTAUTH_URL`, `FEEDER_LAT`, `FEEDER_LON`, `FEEDER_ALT_M`.

`GPS_DEVICE` defaults to `/dev/ttyUSB0`. If the G-Mouse appears as `/dev/ttyACM0`, set it here.

### 5. Start stacks (in order)

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

### 6. Verify

| URL | What you see |
|-----|-------------|
| `http://caravan.local:3000` | Caravan web UI (Tailscale / lokales Netz) |
| `http://caravan.local:8080` | tar1090 ADS-B map (Tailscale / lokales Netz) |
| `https://caravan.c-knox.ch` | Caravan web UI via Cloudflare Tunnel (öffentlich) |

Check live MQTT traffic:

```bash
docker exec -it mqtt mosquitto_sub -t 'caravan/#' -v
```

## Domain caravan.c-knox.ch — Setup-Anleitung

### Voraussetzungen

- Domain `c-knox.ch` muss bei einem Registrar registriert sein
- Cloudflare-Account (kostenlos reicht)

### Schritt 1 — Domain zu Cloudflare übertragen

1. Einloggen auf [dash.cloudflare.com](https://dash.cloudflare.com) → **Add a Site** → `c-knox.ch` eingeben
2. Free-Plan wählen → Cloudflare scannt bestehende DNS-Einträge
3. Cloudflare zeigt zwei **Nameserver** an (z. B. `ada.ns.cloudflare.com`, `bob.ns.cloudflare.com`)
4. Beim Registrar der Domain (`c-knox.ch`) die Nameserver ersetzen → auf die Cloudflare-NS setzen
5. Warten bis die NS-Änderung aktiv ist (5 min–48 h, meist < 1 h) — Cloudflare zeigt grünen Status

> Falls nur die Subdomain `caravan.c-knox.ch` gewünscht ist ohne die ganze Domain zu Cloudflare zu übertragen:  
> Beim bisherigen DNS-Provider einen `CNAME`-Eintrag erstellen (Schritt 3 unten, manuell).

### Schritt 2 — Cloudflare Tunnel erstellen

1. Im Cloudflare Dashboard: **Zero Trust** (linke Sidebar) → **Networks** → **Tunnels** → **Create a tunnel**
2. Tunnel-Typ: **Cloudflared** → **Next**
3. Name: `caravan` → **Save tunnel**
4. Connector installieren: **Docker** wählen — Cloudflare zeigt den Befehl mit dem Token an
5. Den Token kopieren → in `/opt/caravan-lab/.env` eintragen: `TUNNEL_TOKEN=<token>`

### Schritt 3 — Public Hostname konfigurieren

Im Tunnel → Tab **Public Hostnames** → **Add a public hostname**:

| Feld | Wert |
|------|------|
| Subdomain | `caravan` |
| Domain | `c-knox.ch` |
| Type | `HTTP` |
| URL | `caravan-web:3000` |

→ **Save hostname**

Cloudflare erstellt automatisch den DNS-Eintrag:
```
caravan.c-knox.ch  CNAME  <tunnel-id>.cfargotunnel.com
```

### Schritt 4 — Cloudflare Access (optional, zusätzliche Schutzschicht)

Zero Trust → **Access** → **Applications** → **Add an application** → **Self-hosted**:
- Application name: `Caravan`
- Application domain: `caravan.c-knox.ch`
- Policy: E-Mail-Adresse oder IP-Range einschränken

Dies fügt vor der Next.js-App eine zusätzliche Cloudflare-Authentifizierung ein.

### Schritt 5 — .env aktualisieren

```bash
nano /opt/caravan-lab/.env
```

```
NEXTAUTH_URL=https://caravan.c-knox.ch
TUNNEL_TOKEN=<tunnel-token-von-schritt-2>
```

Dann caravan- und cloudflared-Stack neu starten:

```bash
cd /opt/caravan-lab
docker compose -f stacks/caravan/docker-compose.yml    --env-file .env up -d
docker compose -f stacks/cloudflared/docker-compose.yml --env-file .env up -d
```

### Ergebnis

| Zugangsweg | URL / Methode | Wer |
|------------|---------------|-----|
| Web-Dashboard | `https://caravan.c-knox.ch` | Alle (Login + 2FA erforderlich) |
| Admin-Panel | `https://caravan.c-knox.ch/admin` | ADMIN-Benutzer (Zahnrad-Icon) |
| SSH | `ssh idefix@caravan` (via Tailscale) | Techniker mit SSH-Schlüssel |
| tar1090 ADS-B | `http://<tailscale-ip>:8080` | Intern / Tailscale |

---

## Sicherheit

### Firewall (UFW)

```
Eingehend:  SSH (22/tcp) + Tailscale (41641/udp) — alles andere blockiert
Ausgehend:  alles erlaubt
Docker:     alle Container-Ports auf 127.0.0.1 gebunden (Docker umgeht UFW sonst)
```

Firewall-Status prüfen:
```bash
sudo ufw status verbose
```

Firewall neu einrichten (falls nötig):
```bash
bash /opt/caravan-lab/scripts/firewall.sh
```

### SSH-Zugang

Nur per Schlüssel (`PasswordAuthentication no` in `/etc/ssh/sshd_config`).

```bash
# Schlüssel auf neuem Gerät hinzufügen:
ssh-copy-id -i ~/.ssh/id_ed25519.pub idefix@<tailscale-ip>
```

### 2-Faktor-Authentifizierung (TOTP)

**Login-Ablauf mit 2FA:**
1. E-Mail + Passwort eingeben → wird geprüft
2. Bei aktivierter 2FA: automatische Weiterleitung zur TOTP-Seite
3. 6-stelligen Code aus **Google Authenticator** oder **Authy** eingeben → angemeldet

**2FA aktivieren** (aktuell via API, Profil-Seite folgt in Phase 2):
```bash
# Als angemeldeter Benutzer — QR-Code abrufen:
curl -b "<session-cookie>" https://caravan.c-knox.ch/api/auth/totp/setup
# → { qrDataUrl, secret } — QR-Code in Authenticator-App scannen

# 2FA mit erstem Code bestätigen und aktivieren:
curl -X POST -H "Content-Type: application/json" \
  -b "<session-cookie>" \
  -d '{"code":"123456"}' https://caravan.c-knox.ch/api/auth/totp/setup
```

**2FA zurücksetzen** (bei verlorenem Gerät): Admin → Zahnrad-Icon → Benutzer → `2FA reset`.

### Admin-Panel

Erreichbar über das **Zahnrad-Icon** oben rechts im Dashboard (nur für ADMIN-Benutzer sichtbar).  
URL: `https://caravan.c-knox.ch/admin`

| Tab | Inhalt |
|-----|--------|
| **Benutzer** | Liste aller Benutzer, Erstellen, Rollen ändern (USER/ADMIN), 2FA zurücksetzen, Löschen |
| **Konfiguration** | Site-Name, Alarm-Schwellen, Session-Dauer, Routen-Berechtigungen |
| **Sicherheit** | Hinweise zu SSH, Firewall, 2FA |

**Konfigurierbare Einstellungen:**

| Schlüssel | Beschreibung | Standard |
|-----------|-------------|---------|
| `site_name` | Anzeigename der App | `Caravan Telemetrie` |
| `mq2_alarm_ppm` | MQ2 Alarm-Schwelle in ppm | `200` |
| `gps_publish_interval` | GPS Publish-Interval in Sekunden | `5` |
| `session_max_age` | Session-Dauer in Stunden | `24` |
| `routes_enabled` | Routen-Funktion ein- oder ausschalten | `true` |
| `routes_min_role` | Mindestrolle für Routen-Zugriff | `USER` |

### Erster Admin-Benutzer

Nach der ersten DB-Migration einen Admin-Benutzer erstellen:

```bash
docker exec -it caravan-web node -e "
const { PrismaClient } = require('@prisma/client');
const bcrypt = require('bcryptjs');
const prisma = new PrismaClient();
bcrypt.hash('DEIN_PASSWORT', 12).then(h =>
  prisma.user.create({ data: {
    email: 'admin@c-knox.ch',
    password: h,
    role: 'ADMIN',
    name: 'Admin'
  }})
).then(u => { console.log('Created:', u.email); process.exit(0); });
"
```

---

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
    ├── setup.sh                 # First-time Pi setup (Docker, UFW, Tailscale, Timer)
    ├── firewall.sh              # UFW Firewall einrichten / aktualisieren
    ├── deploy.sh                # Smart image-pull + restart (nur bei Änderungen)
    ├── caravan-deploy.service   # systemd Service Unit
    └── caravan-deploy.timer     # systemd Timer (alle 15 min)
```
