OPEN RADAR (GPLv3)
==================

Project Description
-------------------
Open Radar is a Linux-first, self-hostable “radar” dashboard that visualizes moving objects on a map with live updates and trails.

It is designed to be useful without paid services by default (it ships with a simulator), and it supports optional integrations with:
- Publicly available feeds (for example, GTFS-Realtime for transit/passenger rail where published)
- Authorized partner feeds (via a signed webhook ingest)
- Optional vessel feeds (AIS via a WebSocket adapter if the user provides a lawful source)

Legal / Access Note
-------------------
This project is intended for public and authorized data only. Only connect to feeds you are legally allowed to access, and follow each source’s terms of use.

Features
--------
- Live map visualization (OpenStreetMap tiles)
- Active Known Trackings panel (ACTIVE / STALE / OFFLINE)
- Computed speed and heading:
  - Uses reported speed/heading when available
  - Otherwise computes from position deltas
  - Includes simple smoothing to reduce jitter
- Trails / history (last 60 minutes by default)
- Adapters:
  - sim (enabled by default; works offline)
  - gtfs_rt (public transit agencies)
  - ais_ws (optional, user-supplied lawful WebSocket)
- Authorized ingest (HMAC-signed webhook)
- Self-hosted stack via Docker Compose

Architecture
------------
Frontend (React + Vite + Map UI)
- Live map and sidebar
- Connects to backend WebSocket for real-time updates
- Fetches trails/history when selecting an object

Backend (FastAPI + Redis + Postgres/PostGIS)
- Adapters ingest positions -> normalize -> update live state
- Redis stores latest state and publishes updates
- Postgres stores historical position points

Services and Ports
------------------
- Frontend: localhost port 5173
- Backend API: localhost port 8000
- Postgres: localhost port 5432 (PostGIS-enabled)
- Redis: localhost port 6379

System Requirements
-------------------
- Linux recommended
- Docker Engine + Docker Compose v2 (“docker compose”)
- Around 2GB RAM recommended for comfortable local use

Docker permissions:
If your user cannot run Docker without sudo, either:
- run docker commands with sudo, or
- add your user to the docker group:
  sudo usermod -aG docker YOUR_USERNAME
  then log out/in (or start a new shell) to apply.

Install (recommended) — one command
-----------------------------------
From the project directory:
  sudo bash install_open_radar.sh

The installer is intended to:
- install Docker + Compose (or a working equivalent)
- enable/start the Docker daemon
- set docker permissions for your user
- start Open Radar automatically (unless disabled)

Disable autostart:
  OPEN_RADAR_AUTOSTART=0 sudo bash install_open_radar.sh

Run Manually (Docker Compose)
-----------------------------
1) From the project directory:
   cd open-radar
   cp .env.example .env

2) Start:
   sudo docker compose up --build -d

3) Check status:
   sudo docker compose ps

4) Tail logs:
   sudo docker compose logs -f --tail=200 backend

Verify It’s Working
-------------------
Backend health:
  curl -sS 127.0.0.1:8000/api/health
Expected: {"ok":true}

Objects feed (should be non-empty with the simulator enabled):
  curl -sS 127.0.0.1:8000/api/objects

UI:
Open your browser to localhost port 5173.
You should see moving simulated objects (vessels/transit/trains) immediately.

Configuration
-------------
Main config file:
  config/radar.yaml

By default, the simulator should be enabled:
  adapters:
    - type: sim
      enabled: true

Enable a public GTFS-Realtime VehiclePositions feed (optional)
--------------------------------------------------------------
Edit config/radar.yaml:

  - type: gtfs_rt
    enabled: true
    name: Your Agency
    agency_id: your_agency
    domain: TRANSIT
    vehicle_positions_url: "YOUR_GTFS_RT_VEHICLE_POSITIONS_URL"
    poll_seconds: 15

Then restart backend:
  sudo docker compose restart backend

Enable AIS WebSocket adapter (optional)
---------------------------------------
Edit config/radar.yaml:

  - type: ais_ws
    enabled: true
    name: AIS WS
    url_env: AISSTREAM_URL
    api_key_env: AISSTREAM_API_KEY

Set the env vars in .env:
  AISSTREAM_URL=YOUR_WSS_ENDPOINT
  AISSTREAM_API_KEY=YOUR_TOKEN

Restart:
  sudo docker compose restart backend

Authorized Partner Ingest (Webhook)
-----------------------------------
Endpoint:
  POST /api/ingest/webhook/position

Security:
- HMAC signature header:
  X-Radar-Signature: sha256=<hex>
- <hex> is HMAC-SHA256 over the raw request body using RADAR_WEBHOOK_SECRET

Set secret in .env:
  RADAR_WEBHOOK_SECRET=change-me-plz

Payload example:
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

API Endpoints (quick reference)
-------------------------------
- GET /api/health
- GET /api/objects
- GET /api/objects/{object_id}
- GET /api/objects/{object_id}/history?minutes=60&limit=1000
- WS  /api/ws

Troubleshooting
---------------
1) UI loads but shows no objects
- Confirm backend health:
  curl -sS 127.0.0.1:8000/api/health
- Check objects:
  curl -sS 127.0.0.1:8000/api/objects
- Check sidebar filters: set Status to Any status.

2) Permission denied on /var/run/docker.sock
Fix docker group and start a new shell:
  sudo usermod -aG docker YOUR_USERNAME
  newgrp docker

3) Backend exits immediately / API not reachable
Check logs:
  sudo docker compose ps -a
  sudo docker compose logs --tail=200 backend

Common causes:
- Database init errors (schema creation issues)
- DB/Redis not ready at startup (restart backend after DB is fully up)

Restart backend:
  sudo docker compose restart backend

4) Rebuild everything from scratch
  sudo docker compose down
  sudo docker compose up --build -d
  sudo docker compose logs --tail=120 backend

5) localhost oddities (IPv4 vs IPv6)
If “localhost” fails, use 127.0.0.1 in curl commands.

Development
-----------
Run services (foreground):
  sudo docker compose up --build

Frontend-only iteration:
  cd frontend
  npm install
  npm run dev

Backend-only iteration (example):
  cd backend
  pip install -r requirements.txt
  uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

License
-------
GPLv3 (see LICENSE)

Safety and Responsible Use
--------------------------
Open Radar is a tooling foundation for visualization of public and authorized logistics/tracking data.
It does not include proprietary feeds, bypass restrictions, or automate access to restricted systems.
You are responsible for complying with applicable laws and feed provider terms.
