# FediVid

A self-hostable, federated video platform built on ActivityPub. Upload videos, follow people across the Fediverse, comment, boost, chat — all without a central authority.

Built with Mojolicious (Perl), PostgreSQL, Vue 3, and FFmpeg.

## What it does

- **Upload videos** — MP4, WebM, MOV. Transcoded to HLS (360p + 720p) automatically.
- **Federate** — ActivityPub actor, inbox, outbox, WebFinger, HTTP Signatures.
- **Follow anyone** — local users, remote actors on Mastodon / PeerTube / other FediVid instances.
- **Engage** — like, boost, comment, direct message (with live WebSocket delivery).
- **Timelines** — Home (who you follow), Local (this instance), Federated (everything cached).
- **Admin panel** — health, workers, full database browser, user management.
- **Categories & tags** — freeform hashtags plus instance-defined categories.
- **RSS** — instance-wide and per-user feeds.

## Requirements

- Perl 5.26 or higher
- PostgreSQL 12 or higher
- FFmpeg (for transcoding)
- Node.js 18+ and npm (to build the frontend)
- A C toolchain (`gcc`, `make`) — needed to build CPAN modules

On Ubuntu / Debian:

    apt install build-essential libssl-dev libpq-dev postgresql ffmpeg git curl cpanminus

## Installation

### 1. Clone and install Perl dependencies

    git clone <repo-url> fedivid
    cd fedivid
    cpanm --local-lib=local --installdeps . || cpanm Carton && carton install

### 2. Create the database

    createdb -U postgres fedivid_local

### 3. Configure the instance

Edit `instances/local.env`:

    FEDIVID_INSTANCE_NAME=MyVideoSite
    FEDIVID_INSTANCE_DESCRIPTION=A small federated video instance
    FEDIVID_SCHEME=http
    FEDIVID_DOMAIN=localhost:3000
    FEDIVID_BASE_URL=http://localhost:3000
    FEDIVID_LISTEN=http://127.0.0.1:3000
    FEDIVID_DATABASE_URL=postgresql://postgres:YOUR_PASSWORD@localhost/fedivid_local
    FEDIVID_UPLOAD_DIR=uploads/local
    FEDIVID_SESSION_SECRET=change-me-to-a-long-random-string
    FEDIVID_ADMIN_SECRET=change-me-too
    FEDIVID_ALLOW_SIGNUP=1
    FEDIVID_INSTANCE_CONTACT=admin@example.com
    FEDIVID_INSTANCE_RULES=Be kind.|No spam.
    FEDIVID_INSTANCE_CATEGORIES=music|gaming|tech|vlog|sports

Generate the secrets with:

    openssl rand -hex 32

### 4. Apply migrations

    set -a; source instances/local.env; set +a
    carton exec -- script/migrate

### 5. Build the frontend

    cd frontend
    npm ci
    npm run build
    cd ..

### 6. Start the app

In three terminals:

    # Terminal 1: web
    ./script/start_instance.sh local

    # Terminal 2: workers (transcode + delivery + poster)
    ./script/run_workers.sh local

Open http://localhost:3000

### 7. Create the first user

    curl -X POST http://localhost:3000/api/users \
      -H 'Content-Type: application/json' \
      -H 'X-Admin-Token: change-me-too' \
      -d '{"username":"admin","password":"your-strong-password"}'

Log in at http://localhost:3000/login.

## Updating

    cd fedivid

    # 1. Pull the latest code
    git pull

    # 2. Update Perl dependencies if cpanfile changed
    carton install

    # 3. Rebuild the frontend
    cd frontend
    npm ci
    npm run build
    cd ..

    # 4. Apply any new migrations
    set -a; source instances/local.env; set +a
    carton exec -- script/migrate

    # 5. Restart the app
    ./script/start_instance.sh local
    # (workers pick up changes on next restart)

The frontend is served with `Cache-Control: no-cache` on `index.html`, so a normal browser reload picks up the new build. Users do not need to hard-reload.

## Backup

Database:

    pg_dump -U postgres fedivid_local | gzip > backup-$(date +%F).sql.gz

Uploaded files:

    tar czf uploads-$(date +%F).tar.gz uploads/local/

Restore:

    dropdb -U postgres fedivid_local && createdb -U postgres fedivid_local
    gunzip -c backup-YYYY-MM-DD.sql.gz | psql -U postgres fedivid_local
    tar xzf uploads-YYYY-MM-DD.tar.gz

## Daily maintenance

Add to crontab (`crontab -e`):

    0 4 * * * cd /path/to/fedivid && set -a && . instances/local.env && set +a && \
              carton exec -- perl script/cleanup.pl --apply >> /var/log/fedivid-cleanup.log 2>&1

That prunes old completed deliveries, expired remote actors, seen notifications, and orphaned files.

## What runs

Three processes:

- **Web app** (`morbo` in dev, `hypnotoad` in production) — serves HTTP, WebSocket, and the SPA.
- **Worker pool** (`script/run_workers.sh`) — starts three workers:
  - **transcode** — picks pending videos, runs FFmpeg to produce HLS renditions and a poster frame.
  - **delivery** — drains the outbound ActivityPub queue with exponential backoff.
  - **poster** — fetches poster thumbnails for remote videos that the instance caches.

Each worker writes a heartbeat row every few seconds so the admin panel can show whether they are alive.

## Federation

To be reachable from the Fediverse:

1. Set `FEDIVID_SCHEME=https` and `FEDIVID_DOMAIN=your.domain`
2. Put a reverse proxy (Caddy, nginx) in front of the app on port 443
3. Point DNS at the server

Then `@admin@your.domain` is a valid handle that anyone on Mastodon or PeerTube can follow.

## License
CopyLeft
