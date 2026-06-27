# caravan-lab

**Ops / infrastructure repo** for the Caravan Telemetry project.

## Two-repo architecture

| Repo | Was ist drin | Wer arbeitet damit |
|------|-------------|-------------------|
| **[caravan](https://github.com/schmidu-co/caravan)** | Next.js App, Python Workers, Dockerfiles, GitHub Actions CI | Entwickler |
| **[caravan-lab](https://github.com/schmidu-co/caravan-lab)** ← du bist hier | Docker Compose Stacks, Deploy-Scripts, Mosquitto Config, `.env.example` | Ops — läuft auf dem Raspberry Pi 5 |

> **„lab" = Home Lab, kein Testumgebung.**  
> Es gibt nur eine laufende Umgebung: den Pi im Caravan. `caravan-lab` ist das Deployment-/Ops-Repo, keine Staging-Umgebung.

Die Images werden in `caravan` von GitHub Actions gebaut und nach GHCR (`ghcr.io/schmidu-co/*`) gepusht.  
`caravan-lab` holt diese Images und führt sie aus — kein Code wird hier gebaut.

---

## Was dieses System macht

Ein Raspberry Pi 5 im Caravan sammelt Sensor-Daten und macht sie von überall zugänglich — ohne öffentliche IP (CGNAT-Mobilrouter):

- **ADS-B** Flugzeug-Sichtungen via RTL-SDR USB-Dongle
- **GPS** Position via USB G-Mouse (USB-Serial)
- **Sensoren** Temperatur / Luftfeuchte / Luftdruck (Grove BME280) und Gas/Rauch (Grove MQ2)
- **Kamera** Optionaler MJPEG-Stream via Pi Camera Modul 3 *(Phase 2)*

Datenfluss:

```
Hardware → Python Workers → Mosquitto (MQTT) → Next.js Web App → TimescaleDB
                                                    ↑
                             Cloudflare Tunnel (HTTPS · caravan.c-knox.ch)
                             Tailscale          (SSH / Admin)
```

---

## Hardware

| Komponente | Modell | Anschluss |
|-----------|--------|-----------|
| Pi | Raspberry Pi 5, 16 GB RAM | — |
| Kühlung | Offizieller Active Cooler | — |
| Storage | Kingston NVMe 1 TB + M.2 HAT | PCIe |
| Grove HAT | Seeed Grove Base HAT für RPi (SKU 103030275) | GPIO 40-pin |
| ADS-B | RTL-SDR v3/v4 oder Nooelec NESDR SMArt | USB |
| ADS-B Antenne | FlightAware 1090 MHz oder DIY Cantenna | SMA |
| GPS | USB G-Mouse RoHS IPX6 | USB |
| Gas | Grove MQ2 | Analog A0 (Grove HAT ADC) |
| Temp/Feuchte/Druck | Grove BME280 | I2C (Grove) |
| Kamera *(Phase 2)* | Pi Camera Modul 3 | CSI |

> **Router:** TCL MW12VK-2AL-CCH1 mit Swisscom SIM. Mobilrouter sind typischerweise hinter CGNAT — daher Tailscale + Cloudflare Tunnel.  
> **Stromversorgung:** Pi 5 + NVMe + RTL-SDR + Lüfter zieht 12–18 W. Offizielles Pi 5 Netzteil (5.1 V / 5 A) oder 12 V → 5 V DC-DC-Wandler aus dem Caravan-12V-Netz.

---

## Stack-Übersicht

| Stack | Container | Zweck |
|-------|-----------|-------|
| `tailscale` | tailscale | VPN — SSH / Admin (CGNAT-sicher) |
| `mqtt` | mosquitto | Nachrichtenbus zwischen Workers und Web-App |
| `caravan` | caravan-web, caravan-db | Next.js 15 App + TimescaleDB |
| `gpsd` | caravan-gpsd-bridge | USB GPS → gpsd:2947 + MQTT (Live-Position → tar1090) |
| `adsb` | ultrafeeder | RTL-SDR → readsb + tar1090 Karte |
| `sensors` | caravan-sensors | Grove BME280 + MQ2 → MQTT |
| `cloudflared` | cloudflared | Cloudflare Tunnel — Web UI auf :443 |
| `camera` | caravan-camera | Pi Cam MJPEG Stream *(Phase 2)* |

---

## MQTT Topics

Alle Payloads sind JSON. `ts` ist ISO 8601 UTC.

| Topic | Payload |
|-------|---------|
| `caravan/gps/position` | `lat`, `lon`, `alt_m`, `speed_kmh`, `heading`, `ts` |
| `caravan/sensors/bme280` | `temp_c`, `humidity_pct`, `pressure_hpa`, `ts` |
| `caravan/sensors/mq2` | `raw_adc`, `ppm_approx`, `alarm`, `ts` |
| `caravan/adsb/aircraft` | `icao`, `callsign`, `lat`, `lon`, `alt_ft`, `speed_kts`, `ts` |

---

## Installation (Schritt für Schritt)

### Schritt 1 — Raspberry Pi OS flashen

**Raspberry Pi Imager** herunterladen und installieren: [raspberrypi.com/software](https://www.raspberrypi.com/software/)

**OS auswählen:**
```
Choose OS
  └── Raspberry Pi OS (other)
        └── Raspberry Pi OS Lite (64-bit)   ← diese Option wählen
```
> „Lite" = kein Desktop, weniger RAM — alles läuft in Docker. Die aktuelle Version ist Debian Bookworm (Debian 12). 64-bit ist Pflicht für den Pi 5.

**Vor dem Flashen Advanced Options öffnen** (Zahnrad-Icon oder `Ctrl+Shift+X`):

| Einstellung | Wert |
|-------------|------|
| Hostname | `caravan` |
| SSH aktivieren | ✓ (Passwort-Authentifizierung für den ersten Login) |
| Benutzername | `idefix` |
| Passwort | sicheres Passwort setzen |
| WLAN | optional (nur wenn kein LAN-Kabel beim ersten Boot) |
| Locale / Timezone | nach Bedarf |

SD-Karte / NVMe flashen → in den Pi einlegen → booten.

---

### Schritt 2 — WLAN einrichten (falls kein LAN-Kabel)

> Raspberry Pi OS Bookworm verwendet **NetworkManager** statt dem früheren `wpa_supplicant`. Das bedeutet: `raspi-config` kann WLAN **nicht** konfigurieren — stattdessen `nmtui` verwenden.

```bash
ssh idefix@caravan.local    # per LAN verbinden
sudo nmtui                  # grafische Netzwerk-Konfiguration öffnen
```

Im `nmtui`-Menü:
1. **„Activate a connection"** wählen
2. WLAN-Netz auswählen → `<Enter>`
3. Passwort eingeben → verbinden

Verbindung prüfen:
```bash
ping -c 3 1.1.1.1    # Internetverbindung testen
```

---

### Schritt 3 — SSH-Schlüssel einrichten

SSH-Schlüssel ersetzen das Passwort durch ein mathematisches Schlüsselpaar:
- **Privater Schlüssel** → bleibt auf deinem Rechner (niemals weitergeben)
- **Öffentlicher Schlüssel** → wird auf den Pi kopiert

#### 3a — Schlüssel generieren (falls noch keiner vorhanden)

**Prüfen ob bereits ein Schlüssel da ist:**

macOS / Linux (Terminal):
```bash
ls ~/.ssh/id_ed25519.pub
```
Windows (PowerShell):
```powershell
Test-Path "$env:USERPROFILE\.ssh\id_ed25519.pub"
```

Falls nicht vorhanden — neuen Schlüssel erstellen:

macOS / Linux:
```bash
ssh-keygen -t ed25519 -C "caravan-idefix"
# → Enter (Standard-Speicherort übernehmen)
# → Passphrase: leer lassen oder eigene Passphrase setzen
```
Windows (PowerShell):
```powershell
ssh-keygen -t ed25519 -C "caravan-idefix"
```

#### 3b — Öffentlichen Schlüssel auf den Pi kopieren

macOS / Linux:
```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub idefix@caravan.local
# Pi-Passwort eingeben (einmalig)
```

Windows (kein `ssh-copy-id` verfügbar — manuell):
```powershell
# 1. Schlüssel-Inhalt anzeigen und kopieren:
Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub"

# 2. Auf dem Pi einloggen (noch mit Passwort):
ssh idefix@caravan.local

# 3. Auf dem Pi: Schlüssel eintragen
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "HIER_DEN_KOPIERTEN_SCHLUESSEL_EINFUEGEN" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys && exit
```

#### 3c — Schlüssel-Login testen und Passwort-Login deaktivieren

```bash
# Test: Login muss ohne Passwort klappen
ssh idefix@caravan.local

# Auf dem Pi: Passwort-Login deaktivieren (erst NACH erfolgreichem Test!)
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

---

### Schritt 4 — Setup-Script ausführen

```bash
ssh idefix@caravan.local
```

**Option A — direkter Download** (Repo muss öffentlich sein):
```bash
curl -sSL https://raw.githubusercontent.com/schmidu-co/caravan-lab/main/scripts/setup.sh | bash
```

**Option B — via git clone** (funktioniert auch bei privatem Repo):
```bash
sudo git clone https://github.com/schmidu-co/caravan-lab.git /opt/caravan-lab
bash /opt/caravan-lab/scripts/setup.sh
```

Das Script erledigt automatisch:
- I2C und SPI aktivieren
- DVB-Kernel-Module blacklisten (für RTL-SDR USB-Dongle)
- Docker installieren
- `idefix` zu Gruppen hinzufügen: `docker`, `i2c`, `dialout`, `gpio`
- Tailscale installieren
- UFW Firewall einrichten (nur SSH + Tailscale erlaubt)
- Docker-Netzwerk `caravan` erstellen
- Repo nach `/opt/caravan-lab` klonen
- systemd Deploy-Timer einrichten (alle 15 Min)

**Nach dem Script: ausloggen und neu einloggen** (damit Gruppen-Mitgliedschaften aktiv werden):
```bash
exit
ssh idefix@caravan.local
```

---

### Schritt 5 — Tailscale verbinden

Tailscale ist ein VPN das SSH-Zugriff auch ohne öffentliche IP ermöglicht.

**Auth-Key generieren:**
1. [login.tailscale.com](https://login.tailscale.com) → **Settings** → **Keys** → **Generate auth key**
2. **Preauthorized**: ✓ (Häkchen setzen — Pi verbindet sich automatisch ohne manuelle Bestätigung)
3. Key kopieren (sieht aus wie `tskey-auth-xxxxxxxxxxxxxxxx-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`)

```bash
# Key direkt einsetzen, ohne spitze Klammern:
sudo tailscale up --authkey tskey-auth-xxxxxxxxxxxxxxxx-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Verbindung prüfen:
```bash
tailscale status    # Pi sollte als "caravan" erscheinen
```

Ab jetzt ist der Pi von überall via Tailscale erreichbar:
```bash
ssh idefix@caravan    # via Tailscale (von jedem Gerät in deinem Tailnet)
```

---

### Schritt 6 — Umgebung konfigurieren (.env)

```bash
cd /opt/caravan-lab
cp .env.example .env
nano .env
```

Alle Felder mit `REPLACE_ME` müssen ausgefüllt werden. Hier eine genaue Anleitung pro Variable:

#### GHCR_USER und GHCR_TOKEN — Zugriff auf private Docker-Images

Die App-Images liegen auf GitHub Container Registry (GHCR) und sind privat. Du brauchst einen Token um sie herunterzuladen.

1. [github.com](https://github.com) → dein Profil (oben rechts) → **Settings**
2. Links unten: **Developer settings** → **Personal access tokens** → **Fine-grained tokens** → **Generate new token**
3. **Token name:** `caravan-ghcr-read`
4. **Repository access:** `All repositories` (oder nur `caravan`)
5. **Permissions:** `Packages` → `Read` ✓
6. **Generate token** → Token kopieren (beginnt mit `ghp_...`)

```
GHCR_USER=schmidu
GHCR_TOKEN=ghp_DeinGenerierterToken
```

#### POSTGRES_PASSWORD — Datenbank-Passwort

Frei wählbar, aber sicher. Mindestens 16 Zeichen, Buchstaben + Zahlen + Sonderzeichen.

```
POSTGRES_PASSWORD=MeinSicheresPasswort2024!
```

> **Wichtig:** Dieses Passwort nur beim allerersten Start setzen. Danach kann es nicht ohne Datenverlust geändert werden (DB-Volume ist dann bereits mit dem alten Passwort initialisiert).

#### NEXTAUTH_SECRET — Session-Verschlüsselung

Zufälliger Schlüssel für die Verschlüsselung der Login-Sessions. Auf dem Pi generieren:

```bash
openssl rand -base64 32
```

Den ausgegebenen Wert kopieren:
```
NEXTAUTH_SECRET=dXlmYWJjZGVmZ2hpamtsbW5vcHFyc3Q=
```

#### TUNNEL_TOKEN — Cloudflare Tunnel

> Voraussetzung: Domain bei Cloudflare (siehe Abschnitt [Domain-Setup](#domain-caravan-c-knox-ch)) und ein Tunnel muss erstellt sein.

1. [one.dash.cloudflare.com](https://one.dash.cloudflare.com) → **Zero Trust** → **Networks** → **Tunnels**
2. Tunnel anklicken → **Configure** → Tab **Overview**
3. Im angezeigten `cloudflared`-Befehl den Wert nach `--token` kopieren (sehr langer String, beginnt mit `ey...`)

```
TUNNEL_TOKEN=eyJhIjoiMTIz...sehr-langer-string
```

#### NEXTAUTH_URL — Öffentliche URL

```
NEXTAUTH_URL=https://caravan.c-knox.ch
```

#### FEEDER_LAT / FEEDER_LON / FEEDER_ALT_M — Heimat-Koordinaten

GPS-Koordinaten des Heimatstandorts für die ADS-B-Karte (Fallback vor erstem GPS-Fix).  
Koordinaten z. B. über [Google Maps](https://maps.google.com) — Rechtsklick → Koordinaten kopieren.

```
FEEDER_LAT=47.3769
FEEDER_LON=8.5417
FEEDER_ALT_M=408
```

#### GPS_DEVICE — USB-GPS-Gerät

Standard ist `/dev/ttyUSB0`. Falls der G-Mouse als `/dev/ttyACM0` erscheint:
```bash
ls /dev/tty{USB,ACM}*    # zeigt vorhandene Geräte
```

```
GPS_DEVICE=/dev/ttyUSB0
```

---

### Schritt 7 — Docker bei GHCR anmelden

Damit Docker die privaten Images herunterladen kann, muss es sich bei GitHub einloggen:

```bash
source /opt/caravan-lab/.env
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
```

Erfolgsmeldung: `Login Succeeded` ✓

> Dieser Login muss nur einmal manuell gemacht werden. Danach erledigt der automatische Deploy-Timer (`deploy.sh`) den Login bei jedem Pull selbst.

---

### Schritt 8 — Stacks starten (in dieser Reihenfolge)

Die Reihenfolge ist wichtig: MQTT muss vor der Web-App laufen, gpsd vor ADS-B.

```bash
cd /opt/caravan-lab

# 1. Tailscale VPN (zuerst — Fallback-Zugang falls etwas schiefläuft)
docker compose -f stacks/tailscale/docker-compose.yml  --env-file .env up -d

# 2. MQTT Broker (vor allen Workers und der Web-App)
docker compose -f stacks/mqtt/docker-compose.yml        --env-file .env up -d

# 3. Datenbank + Web-App
docker compose -f stacks/caravan/docker-compose.yml     --env-file .env up -d

# 4. GPS (vor ADS-B — ultrafeeder liest Live-Position von gpsd)
docker compose -f stacks/gpsd/docker-compose.yml        --env-file .env up -d

# 5. ADS-B + Sensoren
docker compose -f stacks/adsb/docker-compose.yml        --env-file .env up -d
docker compose -f stacks/sensors/docker-compose.yml     --env-file .env up -d

# 6. Cloudflare Tunnel (zuletzt — erst wenn caravan-web läuft)
docker compose -f stacks/cloudflared/docker-compose.yml --env-file .env up -d
```

Status prüfen:
```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
```

Alle Container sollten `Up` oder `healthy` zeigen. Falls ein Container mit `Restarting` oder `Exited` erscheint → Logs prüfen:
```bash
docker logs <container-name> --tail 20
```

---

### Schritt 9 — Datenbank initialisieren (nur beim ersten Start)

Die Datenbank-Tabellen müssen einmalig erstellt werden. Dieser Schritt verwendet Prisma v6 (wichtig — v7 ist inkompatibel):

```bash
docker exec -u root caravan-web sh -c "
  npm install -g prisma@6 2>/dev/null
  prisma db push --schema /app/prisma/schema.prisma
"
```

Erwartete Ausgabe: `Your database is now in sync with your Prisma schema.` ✓

---

### Schritt 10 — TimescaleDB Hypertables einrichten (nur beim ersten Start)

TimescaleDB optimiert Zeitreihen-Daten mit sogenannten Hypertables. Diese werden einmalig angelegt:

```bash
docker exec caravan-db psql -U caravan -d caravan -c "
  SELECT create_hypertable('gps_positions',   'ts', if_not_exists => TRUE);
  SELECT create_hypertable('bme280_readings', 'ts', if_not_exists => TRUE);
  SELECT create_hypertable('mq2_readings',    'ts', if_not_exists => TRUE);
  SELECT create_hypertable('adsb_sightings',  'ts', if_not_exists => TRUE);
"
```

---

### Schritt 11 — Ersten Admin-Benutzer erstellen

```bash
# ADMIN_PASS durch dein gewünschtes Passwort ersetzen:
docker exec -u root -e ADMIN_PASS='DeinPasswort' caravan-web sh -c '
  cd /tmp && npm install bcryptjs 2>/dev/null
  node -e "
const bcrypt = require(\"/tmp/node_modules/bcryptjs\");
const { PrismaClient } = require(\"/app/node_modules/@prisma/client\");
const p = new PrismaClient();
bcrypt.hash(process.env.ADMIN_PASS, 12)
  .then(h => p.user.create({ data: {
    email: \"admin@c-knox.ch\",
    password: h,
    role: \"ADMIN\",
    name: \"Admin\"
  }}))
  .then(u => { console.log(\"Erstellt:\", u.email); process.exit(0); })
  .catch(e => { console.error(e.message); process.exit(1); });
"
'
```

E-Mail (`admin@c-knox.ch`) und Passwort nach Bedarf anpassen.

Erfolgsmeldung: `Erstellt: admin@c-knox.ch` ✓

---

### Schritt 12 — Dashboard aufrufen und einloggen

| URL | Beschreibung |
|-----|-------------|
| `https://caravan.c-knox.ch` | Dashboard (öffentlich via Cloudflare Tunnel) |
| `http://caravan.local:3000` | Dashboard (lokal / via Tailscale) |
| `http://caravan.local:8080` | tar1090 ADS-B Karte (lokal / via Tailscale) |

Login: E-Mail + Passwort aus Schritt 11.

Live MQTT-Traffic prüfen (optional):
```bash
docker exec -it mqtt mosquitto_sub -t 'caravan/#' -v
```

---

## Domain caravan.c-knox.ch — Setup

### Voraussetzung

- Domain `c-knox.ch` bei einem Registrar registriert
- Cloudflare-Account (kostenloser Plan reicht)

### Schritt 1 — Domain zu Cloudflare übertragen

1. [dash.cloudflare.com](https://dash.cloudflare.com) → **Add a Site** → `c-knox.ch` eingeben
2. **Free**-Plan wählen → Cloudflare scannt DNS-Einträge
3. Cloudflare zeigt zwei Nameserver (z. B. `ada.ns.cloudflare.com`, `bob.ns.cloudflare.com`)
4. Beim Domain-Registrar die Nameserver auf die Cloudflare-NS umstellen
5. Warten bis aktiv (5 Min–48 h, meist < 1 h) — Cloudflare zeigt grünen Status

### Schritt 2 — Cloudflare Tunnel erstellen

1. [one.dash.cloudflare.com](https://one.dash.cloudflare.com) → **Zero Trust** → **Networks** → **Tunnels** → **Create a tunnel**
2. Typ: **Cloudflared** → **Next**
3. Name: `caravan` → **Save tunnel**
4. Auf der nächsten Seite: **Docker** wählen — der Befehl mit dem Token wird angezeigt
5. Den Token (nach `--token`) kopieren → in `.env` eintragen: `TUNNEL_TOKEN=ey...`

### Schritt 3 — Public Hostname konfigurieren

Im Tunnel → Tab **Public Hostnames** → **Add a public hostname**:

| Feld | Wert |
|------|------|
| Subdomain | `caravan` |
| Domain | `c-knox.ch` |
| Type | `HTTP` |
| URL | `caravan-web:3000` |

→ **Save hostname**

> **Wichtig:** URL muss `caravan-web:3000` sein (Docker-interner Hostname), **nicht** `localhost:3000`.

Cloudflare erstellt automatisch den DNS-Eintrag. Ergebnis:
```
caravan.c-knox.ch  →  CNAME  →  <tunnel-id>.cfargotunnel.com
```

### Schritt 4 — Cloudflare Access (optional)

Wenn eine zusätzliche Schutzschicht vor der App gewünscht ist:

**Zero Trust → Access → Applications → Add an application → Self-hosted:**
- Application domain: `caravan.c-knox.ch`
- Policy: E-Mail-Adresse(n) erlauben

> Die App hat bereits eigene Authentifizierung (Login + 2FA). Cloudflare Access fügt eine zweite Schicht hinzu — für die meisten Setups nicht nötig.

---

## Sicherheit

### Firewall (UFW)

```
Eingehend:  SSH (22/tcp) + Tailscale (41641/udp) — alles andere blockiert
Ausgehend:  alles erlaubt
Docker:     alle Container-Ports auf 127.0.0.1 gebunden (Docker umgeht UFW sonst)
```

Status prüfen:
```bash
sudo ufw status verbose
```

Firewall neu einrichten (falls nötig):
```bash
bash /opt/caravan-lab/scripts/firewall.sh
```

### SSH-Zugang

Nur per Schlüssel (`PasswordAuthentication no` in `/etc/ssh/sshd_config`).

Neuen Schlüssel auf einem weiteren Gerät hinzufügen:
```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub idefix@<tailscale-ip>
```

### 2-Faktor-Authentifizierung (TOTP)

Login-Ablauf mit aktivierter 2FA:
1. E-Mail + Passwort → Weiterleitung zur TOTP-Seite
2. 6-stelligen Code aus **Google Authenticator** oder **Authy** eingeben → angemeldet

2FA aktivieren (aktuell via API, UI folgt in Phase 2):
```bash
# Als angemeldeter Benutzer — QR-Code abrufen:
curl -b "<session-cookie>" https://caravan.c-knox.ch/api/auth/totp/setup

# Code bestätigen und 2FA aktivieren:
curl -X POST -H "Content-Type: application/json" \
  -b "<session-cookie>" \
  -d '{"code":"123456"}' https://caravan.c-knox.ch/api/auth/totp/setup
```

2FA zurücksetzen (bei verlorenem Gerät): Admin → Zahnrad-Icon → Benutzer → `2FA reset`

### Admin-Panel

Erreichbar über das **Zahnrad-Icon** oben rechts (nur für ADMIN-Benutzer).  
URL: `https://caravan.c-knox.ch/admin`

| Tab | Inhalt |
|-----|--------|
| **Benutzer** | Liste, Erstellen, Rollen ändern (USER/ADMIN), 2FA zurücksetzen, Löschen |
| **Konfiguration** | Site-Name, Alarm-Schwellen, Routen-Berechtigungen |
| **Sicherheit** | Hinweise zu SSH, Firewall, 2FA |

---

## Häufige Fehler

| Fehler | Ursache | Lösung |
|--------|---------|--------|
| `curl: 404 Not Found` beim Setup | Repo ist privat | Option B (git clone) verwenden |
| `error from registry: unauthorized` | Docker nicht bei GHCR angemeldet | Schritt 7 ausführen |
| `network caravan not found` | Docker-Netzwerk fehlt | `docker network create caravan` |
| `Provided Tunnel token is not valid` | Falscher oder leerer `TUNNEL_TOKEN` in `.env` | Token aus Cloudflare Dashboard kopieren |
| `username is empty` beim GHCR-Login | `GHCR_USER` fehlt in `.env` | Zeile `GHCR_USER=schmidu` hinzufügen |
| `The table does not exist` | DB nicht initialisiert | Schritt 9 ausführen |
| Login schlägt fehl (404) | NextAuth Route fehlt | `docker compose pull` + `up --force-recreate` |
| WLAN geht nicht über `raspi-config` | Bookworm nutzt NetworkManager | `sudo nmtui` verwenden |
| `--skip-generate unknown option` | Zu neue Prisma-Version | `prisma@6` explizit installieren |

---

## Live Caravan-Position in tar1090

Der `gpsd`-Stack betreibt einen gpsd-Daemon auf Port 2947. Der `adsb`-Stack verbindet readsb via `READSB_GPSD_HOST` damit:

- readsb liest die Live-GPS-Position kontinuierlich
- tar1090 zeigt den Empfänger-Standort in Echtzeit (blauer Punkt + Entfernungsringe)
- Kein Neustart nötig wenn der Caravan fährt — der Marker folgt automatisch

Die statischen `FEEDER_LAT`/`FEEDER_LON` in `.env` sind nur Fallback (vor dem ersten GPS-Fix) und Karten-Zentrum.

---

## App als PWA installieren (iPhone / macOS / Windows)

Die Web-App ist eine **Progressive Web App (PWA)** — kein App Store nötig.

| Platform | Vorgehen |
|----------|---------|
| iPhone | Safari → Teilen-Icon → „Zum Home-Bildschirm" |
| macOS | Safari oder Chrome → Installations-Banner oder Adressleisten-Icon |
| Windows | Edge oder Chrome → Installations-Banner oder Adressleisten-Icon |

Die PWA funktioniert offline für die zuletzt gecachte Dashboard-Ansicht. Live-Daten brauchen Verbindung.

---

## Automatisches Deployment

Der systemd Timer ruft `scripts/deploy.sh` alle 15 Minuten auf. Er zieht neue Images und startet nur veränderte Stacks neu.

```bash
# Manuell auslösen:
sudo systemctl start caravan-deploy.service

# Logs verfolgen:
journalctl -u caravan-deploy -f

# Timer-Status:
sudo systemctl status caravan-deploy.timer
```

---

## Repository-Struktur

```
caravan-lab/
├── .env.example                     ← Vorlage für .env (niemals .env committen!)
├── stacks/
│   ├── tailscale/
│   │   └── docker-compose.yml       ← Tailscale VPN
│   ├── mqtt/
│   │   ├── docker-compose.yml       ← Mosquitto Broker
│   │   └── config/mosquitto.conf
│   ├── caravan/
│   │   └── docker-compose.yml       ← Next.js App + TimescaleDB
│   ├── gpsd/
│   │   └── docker-compose.yml       ← GPS Bridge
│   ├── adsb/
│   │   └── docker-compose.yml       ← RTL-SDR / readsb / tar1090
│   ├── sensors/
│   │   └── docker-compose.yml       ← BME280 + MQ2
│   ├── cloudflared/
│   │   └── docker-compose.yml       ← Cloudflare Tunnel
│   └── camera/                      ← Phase 2
│       └── docker-compose.yml
└── scripts/
    ├── setup.sh                     ← Einmaliges Pi-Setup (Docker, UFW, Tailscale, Timer)
    ├── firewall.sh                  ← UFW Firewall einrichten / aktualisieren
    ├── deploy.sh                    ← Automatischer Deploy (zieht neue Images)
    ├── caravan-deploy.service       ← systemd Service Unit
    └── caravan-deploy.timer         ← systemd Timer (alle 15 Min)
```
