# FediVid

A self-hostable, federated video platform built on ActivityPub. Upload videos, follow people across the Fediverse, comment, boost, chat — all without a central authority.

Built with Mojolicious (Perl), PostgreSQL, Vue 3, and FFmpeg.

## What it does

- **Upload videos** — MP4, WebM, MOV. Transcoded to HLS (360p + 720p) automatically.
- **Federate** — ActivityPub actor, inbox, outbox, WebFinger, HTTP Signatures.
- **Follow anyone** — local users, remote actors on other FediVid instances.
- **Engage** — like, boost, comment, direct message (with live WebSocket delivery).
- **Timelines** — Home (who you follow), Local (this instance), Federated (everything cached).
- **Admin panel** — health, workers, dedicated failures view, full database browser, user management.
- **Categories & tags** — freeform hashtags plus instance-defined categories.
- **RSS** — instance-wide and per-user feeds.
- **Dark and light themes** — toggle in the top bar, persisted per browser.

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

See `instances/README.md` for the full list of variables.

### 4. Apply migrations

    set -a; source instances/local.env; set +a
    carton exec -- script/migrate

If `script/migrate` does not exist in your checkout, run migrations
directly:

    set -a; source instances/local.env; set +a
    carton exec -- perl -Ilib -e '
        use Mojo::Base -strict;
        use FediVid;
        my $app = FediVid->new;
        $app->pg->migrations
             ->from_file($app->home->rel_file("migrations.sql"))
             ->migrate;
    '

Migrations are also applied automatically when the app boots in
**development** mode. In production mode (hypnotoad) they must be run
explicitly.

### 5. Build the frontend

    cd frontend
    npm ci
    npm run build
    cd ..

### 6. Start the app

In two terminals:

    # Terminal 1: web
    ./script/start_instance.sh local

    # Terminal 2: workers (transcode + delivery)
    ./script/run_workers.sh local

Open http://localhost:3000

### 7. Create the first user

    curl -X POST http://localhost:3000/api/users \
      -H 'Content-Type: application/json' \
      -H 'X-Admin-Token: change-me-too' \
      -d '{"username":"admin","password":"your-strong-password"}'

Log in at http://localhost:3000/login.

## Testing

The test suite uses a dedicated database. Create it once:

    createdb -U postgres fedivid_test

Then run the suite:

    carton exec -- prove -l t/

Individual test file:

    carton exec -- prove -l t/23_videos.t

The tests reset the schema per file, so they are safe to run
repeatedly and in any order.

## Development with two instances

To test federation end-to-end, run two instances on the same machine.

Create a second env file:

    cp instances/local.env instances/peer1.env

Change at least:

    FEDIVID_INSTANCE_NAME=peer1
    FEDIVID_DOMAIN=localhost:3001
    FEDIVID_BASE_URL=http://localhost:3001
    FEDIVID_LISTEN=http://127.0.0.1:3001
    FEDIVID_DATABASE_URL=postgresql://postgres:YOUR_PASSWORD@localhost/fedivid_peer1
    FEDIVID_UPLOAD_DIR=uploads/peer1
    FEDIVID_SESSION_SECRET=peer1-dev-session-secret
    FEDIVID_ADMIN_SECRET=test-admin-token-peer1

Both env files need:

    FEDIVID_ALLOW_INSECURE_FETCH=1

(This lets the two instances talk over plain HTTP on loopback.
Never enable it in production.)

Create the second database:

    createdb -U postgres fedivid_peer1

Run four terminals:

    ./script/start_instance.sh local        # http://localhost:3000
    ./script/start_instance.sh peer1        # http://localhost:3001
    ./script/run_workers.sh local
    ./script/run_workers.sh peer1

Then log in on each and try:

1. On instance A, follow a user on instance B via `/explore`.
2. Upload a video on A with tags. Wait for transcode.
3. On B, visit `/remote/<user>@localhost:3000` — the video appears with poster and tags.
4. Send a DM between them.
5. Delete a user on A. On B, the corresponding conversation disappears.

## Seeding for stress tests

`script/seed.pl` populates the database with a large amount of fake
data, useful for exercising the admin panel and checking UI behaviour
under load.

    # wipe everything, create 10,000 users and millions of related rows
    ./script/seed.sh local --reset

    # additive
    ./script/seed.sh local

    # custom counts
    ./script/seed.sh local --reset --users 50000 --password hunter2

All seeded users share the same RSA keypair. This is fine for local
dev but **never use it on a production instance** — every seeded user
would share a signing key.

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

That prunes old completed deliveries, expired rate-limit windows,
seen notifications, orphaned remote actors, and orphaned upload/HLS
files. It **preserves avatars** and cleans stale HLS directories.

Run without `--apply` first to see what would be deleted.

## What runs

Two processes:

- **Web app** (`morbo` in dev, `hypnotoad` in production) — serves HTTP, WebSocket, and the SPA.
- **Worker pool** (`script/run_workers.sh`) — starts two workers:
  - **transcode** — picks pending videos, runs FFmpeg to produce HLS renditions and a poster frame. Recovers stuck `processing` rows on startup and every 5 minutes.
  - **delivery** — drains the outbound ActivityPub queue with exponential backoff.

Both workers use transactional row-claiming with `SELECT ... FOR UPDATE SKIP LOCKED` and a lease timestamp, so it is safe to run multiple copies of each.

Each worker writes a heartbeat row every few seconds so the admin panel can show whether they are alive.

## Federation

To be reachable from the Fediverse:

1. Set `FEDIVID_SCHEME=https` and `FEDIVID_DOMAIN=your.domain`
2. Put a reverse proxy (Caddy, nginx) in front of the app on port 443
3. Point DNS at the server
4. Make sure NTP is running — HTTP signature verification has a 15-minute freshness window
5. Set `FEDIVID_ALLOW_INSECURE_FETCH=0`

Then `@admin@your.domain` is a valid handle that anyone on another
FediVid instance can follow.

For deployment instructions, see `DEPLOY.md` (bare-metal and Docker).

## Security notes

- HTTP signatures are verified for every inbound federation request.
- Signature freshness is enforced — requests older than 15 minutes are rejected.
- Actor documents are verified against the URL they were fetched from (anti-impersonation).
- The `actor` field of an incoming activity must match the actor that signed the request.
- URL fetching is guarded against SSRF — private IPs, `localhost`, and cloud metadata endpoints are blocked.
- Passwords are hashed with bcrypt (cost 12).
- Session cookies are HMAC-signed and `HttpOnly`.
- The admin API redacts `password_hash` and `private_key_pem` in the table browser.

## Architecture

    FediVid.pm                Application bootstrap, routes, config
    FediVid/
      Auth.pm                 Session + HTTP Signature authentication
      ActivityHandler.pm      Inbound activity dispatcher (Follow, Like, ...)
      Delivery.pm             Outbound activity delivery (signs and POSTs)
      DeliveryQueue.pm        Enqueue activities for delivery
      Signature.pm            sign_request / verify_request / verify_digest
      RemoteActor.pm          Fetch and cache remote actor documents
      WebFinger.pm            Resolve @user@host to an actor URL
      URLGuard.pm             SSRF protection for outbound URLs
      Transcoder.pm           FFmpeg wrapper for HLS output
      VideoProbe.pm           ffprobe wrapper
      Password.pm             bcrypt hashing
      Notifications.pm        Create notification rows
      RateLimit.pm            DB-backed rate limiter
      WorkerHeartbeat.pm      Worker liveness pings
      Outbox.pm               Fetch a remote actor's recent videos

    Controller/
      Actor.pm                /users/:u, /users/:u/inbox, outbox
      WebFinger.pm            /.well-known/webfinger
      Users.pm                Account creation
      Sessions.pm             Login / logout / session cookie
      Passwords.pm            Password changes
      Videos.pm               Upload, HLS serving
      Feed.pm                 RSS
      (Api*)                  JSON endpoints for the SPA

    script/
      start_instance.sh       Launch the web app for an instance
      run_workers.sh          Launch the workers for an instance
      delivery_worker.pl      Outbound delivery worker
      transcode_worker.pl     Transcode worker
      cleanup.pl              Maintenance tasks
      seed.pl                 Dev seed (large-scale fake data)
      migrate                 Run pending migrations

    frontend/                 Vue 3 SPA, built with Vite

## License
CopyLeft
