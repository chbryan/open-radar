````markdown
# Open Radar (GPLv3)

Open Radar is a **Linux-first**, self-hostable **real-time “radar” dashboard** that visualizes moving objects on a map with live updates and trails.

It’s designed to be useful **without paid services** by default (it ships with a simulator), and it supports **optional integrations** with:
- **Publicly available feeds** (e.g., GTFS-Realtime for transit / passenger rail where published)
- **Authorized partner feeds** (via a signed webhook ingest)
- **Optional vessel feeds** (AIS via a WebSocket adapter if the user provides a lawful source)

> **Legal / access note**
> This project is intended for **public + authorized** data only. Only connect to feeds you are legally allowed to access, and follow each source’s terms of use.

---

## Features

- **Live map visualization** (Leaflet + OpenStreetMap tiles)
- **Active Known Trackings** panel (ACTIVE / STALE / OFFLINE)
- **Computed speed + heading**
  - Uses reported speed/heading when available
  - Otherwise computes from position deltas
  - Includes simple smoothing to reduce jitter
- **Trails / history** (last 60 minutes by default)
- **Adapters**
  - `sim` (enabled by default, free, works offline)
  - `gtfs_rt` (public transit agencies)
  - `ais_ws` (optional, user-supplied lawful WebSocket)
- **Authorized ingest** (HMAC-signed webhook)
- **Self-hosted stack** via Docker Compose

---

## Architecture

**Frontend** (React + Vite + Leaflet)
- Live map + sidebar
- Connects to backend WebSocket for real-time updates
- Fetches trails/history on selection

**Backend** (FastAPI + Redis + Postgres/PostGIS)
- Adapters ingest positions → normalize → update live state
- Redis stores latest object state + publishes updates
- Postgres stores historical position points

**Services / Ports**
- Frontend: `http://localhost:5173`
- Backend API: `http://localhost:8000`
- Postgres: `localhost:5432` (PostGIS-enabled)
- Redis: `localhost:6379`

---

## System Requirements

- Linux (recommended)
- Docker Engine + Docker Compose v2 (`docker compose`)
- ~2GB RAM recommended for comfortable local use

If your user cannot run Docker commands without sudo, you either need:
- docker group permissions (`usermod -aG docker <user>`) **or**
- run docker commands with `sudo`

---

## Install (recommended) — one command

From the project directory:

```bash
sudo bash install_open_radar.sh
````

This installer is intended to:

* install Docker + Compose (or a working equivalent)
* enable/start the Docker daemon
* set docker permissions for your user
* start Open Radar automatically (unless disabled)

### Disable autostart

```bash
OPEN_RADAR_AUTOSTART=0 sudo bash install_open_radar.sh
```

---

## Run manually (Docker Compose)

```bash
cd open-radar
cp .env.example .env
sudo docker compose up --build -d
```

Check status:

```bash
sudo docker compose ps
```

Tail logs:

```bash
sudo docker compose logs -f --tail=200 backend
```

---

## Verify It’s Working

### Backend health

```bash
curl -sS http://127.0.0.1:8000/api/health && echo
```

Expected:

```json
{"ok":true}
```

### Objects feed (should be non-empty with the simulator enabled)

```bash
curl -sS http://127.0.0.1:8000/api/objects | head -c 400 && echo
```

### UI

Open:

* `http://localhost:5173`

You should see moving simulated objects (vessels/transit/trains) immediately.

> If the map is empty, check the sidebar filter: set **Status** to **Any** or confirm the backend is healthy.

---

## Configuration

Main config:

* `config/radar.yaml`

By default, the simulator is enabled:

```yaml
adapters:
  - type: sim
    enabled: true
```

### Enable a public GTFS-Realtime feed (Transit / Passenger Rail where published)

Edit `config/radar.yaml`:

```yaml
- type: gtfs_rt
  enabled: true
  name: Your Agency
  agency_id: your_agency
  vehicle_positions_url: "https://example.com/vehiclepositions.pb"
  poll_seconds: 15
```

Then restart backend:

```bash
sudo docker compose restart backend
```

### Enable AIS WebSocket (optional)

Edit `config/radar.yaml` and set:

```yaml
- type: ais_ws
  enabled: true
  url_env: AISSTREAM_URL
  api_key_env: AISSTREAM_API_KEY
```

Set the env vars in `.env`:

```bash
AISSTREAM_URL=wss://your-provider/ws
AISSTREAM_API_KEY=your_token_here
```

Restart:

```bash
sudo docker compose restart backend
```

---

## Authorized Partner Ingest (Webhook)

Endpoint:

* `POST /api/ingest/webhook/position`

Security:

* HMAC signature header:

  * `X-Radar-Signature: sha256=<hex>`
* `<hex>` is HMAC-SHA256 over the raw request body using `RADAR_WEBHOOK_SECRET`

Set secret in `.env`:

```bash
RADAR_WEBHOOK_SECRET=change-me-please
```

Payload example:

```json
{
  "domain": "TRAIN",
  "public_id": "partner-train-042",
  "display_name": "Partner Train 042",
  "ts_utc": "2026-01-12T12:34:56Z",
  "lat": 41.881,
  "lon": -87.623,
  "reported_speed_mps": 14.2,
  "reported_heading_deg": 270.0,
  "operator": "PartnerCo",
  "extra": { "note": "authorized feed" }
}
```

More details:

* `docs/authorized-ingest.md`

---

## API Endpoints (quick reference)

* `GET /api/health` — health check
* `GET /api/objects` — current live object states (filters supported)
* `GET /api/objects/{object_id}` — single object state
* `GET /api/objects/{object_id}/history?minutes=60&limit=1000` — trail points
* `WS /api/ws` — live updates (snapshot + incremental updates)

---

## Repo Layout

```
open-radar/
  backend/
    app/
      adapters/        # sim, gtfs_rt, ais_ws
      api/             # REST + WebSocket routes
      core/            # config, db, tracker, redis client
  frontend/
    src/
      components/      # MapView, Sidebar
  config/
    radar.yaml         # adapters + runtime config
  docs/
    authorized-ingest.md
  docker-compose.yml
  install_open_radar.sh
  LICENSE
  README.md
```

---

## Troubleshooting

### 1) UI loads but shows no objects

* Confirm backend health:

  ```bash
  curl -sS http://127.0.0.1:8000/api/health && echo
  ```
* If healthy, check objects:

  ```bash
  curl -sS http://127.0.0.1:8000/api/objects | head -c 400 && echo
  ```
* Check sidebar filters: set **Status** to **Any status**.

### 2) `permission denied` on `/var/run/docker.sock`

Your user isn’t in the docker group (or your shell hasn’t refreshed group membership).

Fix:

```bash
sudo usermod -aG docker "$USER"
newgrp docker
```

### 3) Backend exits immediately / API not reachable

Check logs:

```bash
sudo docker compose ps -a
sudo docker compose logs --tail=200 backend
```

Common causes and fixes:

**A) Postgres init error: “cannot insert multiple commands into a prepared statement”**

* Cause: asyncpg requires one SQL statement per execute.
* Fix: ensure `backend/app/core/db.py` executes `CREATE TABLE` and `CREATE INDEX` as separate statements.

**B) Race at startup: Postgres/Redis not ready**

* Fix: backend includes startup retries; also ensure db/redis containers are running:

  ```bash
  sudo docker compose ps
  ```

Restart:

```bash
sudo docker compose restart backend
```

### 4) Rebuild everything from scratch

```bash
sudo docker compose down
sudo docker compose up --build -d
sudo docker compose logs --tail=120 backend
```

### 5) “localhost” vs IPv6 oddities

If `curl http://localhost:8000/...` fails but `127.0.0.1` works, use:

```bash
curl -4 http://127.0.0.1:8000/api/health
```

---

## Development

Run services:

```bash
sudo docker compose up --build
```

Frontend-only iteration (inside `frontend/`):

```bash
npm install
npm run dev
```

Backend-only iteration (inside `backend/`):

```bash
pip install -r requirements.txt
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

---

## License

GPLv3 — see `LICENSE`.

---

## Safety & Responsible Use

Open Radar is a tooling foundation for visualization of **public** and **authorized** logistics / tracking data.
It does not include proprietary feeds, bypass restrictions, or automate access to restricted systems.
You are responsible for complying with applicable laws and feed provider terms.

```:0]{index=0}
```
