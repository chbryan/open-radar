# Open Radar (GPLv3)

A Linux-first, self-hostable **live "radar" dashboard** for publicly available feeds (and optional authorized integrations),
supporting:
- **Transit vehicles** (and passenger trains where published) via **GTFS-Realtime**
- **Vessels** via an AIS WebSocket adapter (optional) or simulator
- **Trains** via GTFS-RT (public agencies) and/or authorized partner webhooks

> This project is designed for **public + authorized** logistics visualization.  
> Only connect data sources you are legally permitted to access, and follow each source's terms of use.

## Quickstart (Docker Compose)

Prereqs: Docker + Docker Compose on Linux.

```bash
cd open-radar
cp .env.example .env
docker compose up --build
```

- Backend API: http://localhost:8000
- Frontend UI: http://localhost:5173

The default config enables the **simulator** so you can test instantly.

## Configure feeds

Edit `config/radar.yaml`:

- Enable GTFS-RT (public transit):
  - Add an agency `vehicle_positions_url`
  - Optionally `trip_updates_url` and `alerts_url`

- Enable AIS (optional):
  - Provide `AISSTREAM_URL` (WebSocket) and any required token(s) via environment variables

## Authorized partner ingest (webhook)

Partners can POST normalized position events to:

- `POST /api/ingest/webhook/position`

Use HMAC signing header:
- `X-Radar-Signature: sha256=<hex>`

Signature is HMAC-SHA256 over the raw request body using `RADAR_WEBHOOK_SECRET`.

See `docs/authorized-ingest.md`.

## License

GPLv3. See `LICENSE`.
