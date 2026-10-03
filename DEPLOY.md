# FediVid — Deployment Guide

Two supported deployment shapes:

1. **Bare-metal** — Debian (or similar) with Perl, Postgres, Nginx, and systemd.
2. **Docker Compose** — everything in containers, one command.

Both run the same code with the same environment files. Pick whichever
suits your infrastructure.

Federation requires a **stable HTTPS origin** and a **clock in sync**.
Both are covered below. The signature freshness window is 15 minutes,
so the host's clock must be accurate.

---

## 0. Common prerequisites

Whichever path you take, you will need:

- A public DNS name pointing at the server (or reverse proxy).
- A TLS certificate for that name. Let's Encrypt via certbot or Caddy's
  built-in ACME are both fine.
- NTP running. On Debian, `systemd-timesyncd` is enabled by default.
  Verify with:

      timedatectl status

  The `System clock synchronized: yes` line must be `yes`.

- **A production env file.** Copy `instances/local.env` to
  `instances/prod.env` and change at minimum:

      FEDIVID_INSTANCE_NAME=<your site name>
      FEDIVID_SCHEME=https
      FEDIVID_DOMAIN=<your public domain>
      FEDIVID_BASE_URL=https://<your public domain>
      FEDIVID_LISTEN=http://127.0.0.1:3000
      FEDIVID_DATABASE_URL=postgresql://USER:PASSWORD@HOST/DB
      FEDIVID_UPLOAD_DIR=/var/lib/fedivid/uploads
      FEDIVID_SESSION_SECRET=<64 hex chars>
      FEDIVID_ADMIN_SECRET=<64 hex chars>
      FEDIVID_ALLOW_SIGNUP=0
      FEDIVID_ALLOW_INSECURE_FETCH=0

  Generate secrets with:

      openssl rand -hex 64

  Run it twice — one for `SESSION_SECRET`, one for `ADMIN_SECRET`.
  **Never reuse the dev values in production.**

- **A `cpanfile.snapshot`.** Run `carton install` once locally and commit
  the resulting snapshot so production installs deterministic versions.

- **A migrations step.** The app runs migrations automatically only in
  development mode. Under hypnotoad it runs in production mode, so the
  schema must be migrated by hand the first time. See the migration
  section below.

---

## 1. First-time migration

The app does **not** migrate in production mode. Before starting any
production process, run once:

    set -a
    source instances/prod.env
    set +a
    carton exec -- perl -Ilib -e '
        use Mojo::Base -strict;
        use FediVid;
        my $app = FediVid->new;
        $app->pg->migrations
             ->from_file($app->home->rel_file("migrations.sql"))
             ->migrate;
        print "migrated\n";
    '

Run this:

- once when you first deploy,
- and again after every deployment that adds new rows to `migrations.sql`.

It is idempotent — re-running it applies only the migrations that have
not yet been applied.

---

## 2. Path A — Bare-metal (Debian)

### 2.1 Packages

    sudo apt update
    sudo apt install -y \
        perl cpanminus carton \
        postgresql postgresql-contrib \
        nginx certbot python3-certbot-nginx \
        ffmpeg git \
        build-essential libssl-dev libpq-dev libexpat1-dev \
        pkg-config

### 2.2 A dedicated user

    sudo adduser --system --group --home /home/fedivid fedivid

Everything below runs as `fedivid` unless noted.

### 2.3 Postgres

Create a role and a database:

    sudo -u postgres psql -c "CREATE ROLE fedivid LOGIN PASSWORD '<strong-password>';"
    sudo -u postgres psql -c "CREATE DATABASE fedivid OWNER fedivid;"

Ensure Postgres listens only on loopback (default on Debian):

    grep listen_addresses /etc/postgresql/*/main/postgresql.conf

If it is `localhost`, you are done.

### 2.4 Application directory

    sudo -u fedivid git clone <repo> /home/fedivid/app
    cd /home/fedivid/app
    sudo -u fedivid carton install --deployment

Create the upload directory:

    sudo mkdir -p /var/lib/fedivid/uploads
    sudo chown -R fedivid:fedivid /var/lib/fedivid

Copy your env file:

    sudo cp instances/local.env instances/prod.env
    sudo chown fedivid:fedivid instances/prod.env
    sudo chmod 600 instances/prod.env
    # edit instances/prod.env

### 2.5 First migration

    cd /home/fedivid/app
    set -a; source instances/prod.env; set +a
    carton exec -- perl -Ilib -e '
        use Mojo::Base -strict;
        use FediVid;
        my $app = FediVid->new;
        $app->pg->migrations
             ->from_file($app->home->rel_file("migrations.sql"))
             ->migrate;
        print "migrated\n";
    '

### 2.6 systemd units

Create the following files under `/etc/systemd/system/`. Adjust
`User`, `Group`, `WorkingDirectory`, and `EnvironmentFile` to match
your paths.

**`fedivid-web.service`**

    [Unit]
    Description=FediVid web (hypnotoad)
    After=network.target postgresql.service

    [Service]
    Type=forking
    User=fedivid
    Group=fedivid
    WorkingDirectory=/home/fedivid/app
    EnvironmentFile=/home/fedivid/app/instances/prod.env
    ExecStart=/usr/local/bin/carton exec -- hypnotoad -f script/fedivid
    ExecStop=/usr/local/bin/carton exec -- hypnotoad -s script/fedivid
    Restart=on-failure
    RestartSec=5

    [Install]
    WantedBy=multi-user.target

**`fedivid-worker-delivery.service`**

    [Unit]
    Description=FediVid delivery worker
    After=network.target postgresql.service

    [Service]
    Type=simple
    User=fedivid
    Group=fedivid
    WorkingDirectory=/home/fedivid/app
    EnvironmentFile=/home/fedivid/app/instances/prod.env
    ExecStart=/usr/local/bin/carton exec -- perl script/delivery_worker.pl --loop
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target

**`fedivid-worker-transcode.service`**

    [Unit]
    Description=FediVid transcode worker
    After=network.target postgresql.service

    [Service]
    Type=simple
    User=fedivid
    Group=fedivid
    WorkingDirectory=/home/fedivid/app
    EnvironmentFile=/home/fedivid/app/instances/prod.env
    ExecStart=/usr/local/bin/carton exec -- perl script/transcode_worker.pl --loop
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target

Note: the delivered project's `FediVid.pm` sets a hypnotoad `pid_file`
under `/srv/fedivid/`. Either create that directory and give the
`fedivid` user ownership, or override the value in your env file
before the first start.

    sudo mkdir -p /srv/fedivid
    sudo chown fedivid:fedivid /srv/fedivid

Enable and start:

    sudo systemctl daemon-reload
    sudo systemctl enable --now \
        fedivid-web \
        fedivid-worker-delivery \
        fedivid-worker-transcode

Check status:

    sudo systemctl status fedivid-web

    sudo journalctl -u fedivid-web -f

### 2.7 Reverse proxy (nginx)

Create `/etc/nginx/sites-available/fedivid`:

    server {
        listen 80;
        server_name <your domain>;
        return 301 https://$host$request_uri;
    }

    server {
        listen 443 ssl http2;
        server_name <your domain>;

        ssl_certificate     /etc/letsencrypt/live/<your domain>/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/<your domain>/privkey.pem;

        client_max_body_size 500M;

        location / {
            proxy_pass http://127.0.0.1:3000;
            proxy_http_version 1.1;
            proxy_set_header Host              $host;
            proxy_set_header X-Real-IP         $remote_addr;
            proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # WebSocket
            proxy_set_header Upgrade           $http_upgrade;
            proxy_set_header Connection        "upgrade";

            proxy_read_timeout 3600s;
        }
    }

Then:

    sudo ln -s /etc/nginx/sites-available/fedivid /etc/nginx/sites-enabled/
    sudo nginx -t
    sudo certbot --nginx -d <your domain>
    sudo systemctl reload nginx

The nginx worker must be able to read the certificate files. certbot
handles permissions automatically.

### 2.8 Deploying an update

    cd /home/fedivid/app
    sudo -u fedivid git pull
    sudo -u fedivid carton install --deployment
    # re-run migration if migrations.sql changed
    sudo systemctl restart fedivid-web
    sudo systemctl restart fedivid-worker-delivery
    sudo systemctl restart fedivid-worker-transcode

### 2.9 Backups

A daily `pg_dump` plus `rsync` of the uploads directory. Example
`/etc/cron.daily/fedivid-backup`:

    #!/bin/sh
    set -eu
    BACKUP_DIR=/var/backups/fedivid
    mkdir -p "$BACKUP_DIR"
    sudo -u postgres pg_dump fedivid | gzip > "$BACKUP_DIR/db-$(date +%F).sql.gz"
    rsync -a --delete /var/lib/fedivid/uploads/ "$BACKUP_DIR/uploads/"
    find "$BACKUP_DIR" -name 'db-*.sql.gz' -mtime +30 -delete

Make it executable:

    sudo chmod +x /etc/cron.daily/fedivid-backup

Send the backup directory to off-site storage (rsync, borg, restic, s3,
whatever you prefer). A backup that lives only on the same machine is
not a backup.

---

## 3. Path B — Docker

### 3.1 What you get

A single `docker-compose` stack with:

- `web` — hypnotoad behind an internal port
- `worker-delivery` — delivery worker
- `worker-transcode` — transcode worker
- `db` — Postgres
- `proxy` — Caddy (TLS termination, ACME built in)

Data lives in named volumes. Configuration comes from `.env` and
`instances/prod.env`.

### 3.2 Files

Add these three files to the project root.

**`Dockerfile`**

    FROM debian:bookworm-slim

    RUN apt-get update && apt-get install -y --no-install-recommends \
            perl cpanminus carton \
            build-essential libssl-dev libpq-dev libexpat1-dev \
            ffmpeg ca-certificates \
        && rm -rf /var/lib/apt/lists/*

    WORKDIR /app

    COPY cpanfile cpanfile.snapshot* ./
    RUN carton install --deployment

    COPY . .

    ENV MOJO_MODE=production
    EXPOSE 3000

    CMD ["carton", "exec", "--", "hypnotoad", "-f", "script/fedivid"]

**`docker-compose.yml`**

    services:
      db:
        image: postgres:16
        restart: unless-stopped
        environment:
          POSTGRES_USER: fedivid
          POSTGRES_PASSWORD: change-me
          POSTGRES_DB: fedivid
        volumes:
          - db-data:/var/lib/postgresql/data
        healthcheck:
          test: ["CMD-SHELL", "pg_isready -U fedivid -d fedivid"]
          interval: 10s
          timeout: 5s
          retries: 5

      web:
        build: .
        restart: unless-stopped
        depends_on:
          db:
            condition: service_healthy
        env_file: instances/prod.env
        environment:
          FEDIVID_DATABASE_URL: postgresql://fedivid:change-me@db/fedivid
          FEDIVID_LISTEN: http://0.0.0.0:3000
          FEDIVID_UPLOAD_DIR: /var/lib/fedivid/uploads
        volumes:
          - uploads:/var/lib/fedivid/uploads
        ports:
          - "127.0.0.1:3000:3000"

      worker-delivery:
        build: .
        restart: unless-stopped
        depends_on:
          db:
            condition: service_healthy
        env_file: instances/prod.env
        environment:
          FEDIVID_DATABASE_URL: postgresql://fedivid:change-me@db/fedivid
          FEDIVID_UPLOAD_DIR: /var/lib/fedivid/uploads
        volumes:
          - uploads:/var/lib/fedivid/uploads
        command: ["carton", "exec", "--", "perl", "script/delivery_worker.pl", "--loop"]

      worker-transcode:
        build: .
        restart: unless-stopped
        depends_on:
          db:
            condition: service_healthy
        env_file: instances/prod.env
        environment:
          FEDIVID_DATABASE_URL: postgresql://fedivid:change-me@db/fedivid
          FEDIVID_UPLOAD_DIR: /var/lib/fedivid/uploads
        volumes:
          - uploads:/var/lib/fedivid/uploads
        command: ["carton", "exec", "--", "perl", "script/transcode_worker.pl", "--loop"]

      proxy:
        image: caddy:2
        restart: unless-stopped
        depends_on:
          - web
        ports:
          - "80:80"
          - "443:443"
        volumes:
          - ./Caddyfile:/etc/caddy/Caddyfile:ro
          - caddy-data:/data
          - caddy-config:/config

    volumes:
      db-data:
      uploads:
      caddy-data:
      caddy-config:

**`Caddyfile`**

    <your domain> {
        encode gzip
        request_body {
            max_size 500MB
        }

        reverse_proxy web:3000 {
            header_up Host {host}
            header_up X-Forwarded-Proto {scheme}
        }
    }

Caddy obtains and renews TLS certificates automatically. No certbot
needed.

### 3.3 Change the defaults

Before starting:

- Replace `change-me` in `docker-compose.yml` with a strong password.
- In `instances/prod.env`, set `FEDIVID_DATABASE_URL` to point at the
  `db` service (see the `environment:` block, which overrides it),
  `FEDIVID_BASE_URL` to your HTTPS URL, and both secrets to fresh
  random values.
- Replace `<your domain>` in `Caddyfile`.

### 3.4 First run

    docker compose build
    docker compose up -d db

Wait for Postgres to be healthy:

    docker compose logs -f db

Then run the migration inside the web container:

    docker compose run --rm web \
        carton exec -- perl -Ilib -e '
            use Mojo::Base -strict;
            use FediVid;
            my $app = FediVid->new;
            $app->pg->migrations
                 ->from_file($app->home->rel_file("migrations.sql"))
                 ->migrate;
            print "migrated\n";
        '

Then start everything:

    docker compose up -d

Check:

    docker compose ps
    docker compose logs -f web

### 3.5 Updating

    git pull
    docker compose build
    docker compose up -d

If `migrations.sql` changed, run the migration command again before
restarting `web`.

### 3.6 Backups

Postgres data lives in the `db-data` volume and uploads in `uploads`.
Back both up:

    docker compose exec db pg_dump -U fedivid fedivid \
        | gzip > /var/backups/fedivid/db-$(date +%F).sql.gz

    docker run --rm \
        -v fedivid_uploads:/data \
        -v /var/backups/fedivid:/backup \
        alpine tar czf /backup/uploads-$(date +%F).tar.gz -C /data .

Put those commands in a cron job and ship the result off-site.

---

## 4. Operating notes

### After deploying

1. Sign in to `/admin` (or create the first user with the admin token)
   and confirm the **Workers** panel shows both workers as `active`.
2. Upload a test video. Wait for the transcode worker to mark it
   `ready`. Play it.
3. Follow a peer on another instance. Verify the follow appears under
   `/following` and — on their side — under their followers.
4. Send a DM to a remote peer.
5. Watch the delivery worker's log for `delivered` lines. If you see
   `FAILED`, check the peer's reachability and the error text.

### When federation is not working

- **Signatures rejected** — clock drift. Check `timedatectl status` on
  both hosts.
- **`URL rejected: cannot resolve`** — DNS is broken from the server, or
  `FEDIVID_ALLOW_INSECURE_FETCH` is on and the peer uses HTTP only.
  In production, set `FEDIVID_ALLOW_INSECURE_FETCH=0`.
- **`remote returned 4xx`** — the peer's inbox rejected the activity.
  Usually a signature mismatch or a missing public key on their side.
- **`cannot_fetch_actor`** — WebFinger resolution failed. Verify from
  the server: `curl -s 'https://<peer>/.well-known/webfinger?resource=acct:user@peer'`.

### Logs

- Bare-metal: `journalctl -u fedivid-web -f`, `journalctl -u fedivid-worker-delivery -f`.
- Docker: `docker compose logs -f web`, `docker compose logs -f worker-delivery`.

### Scaling

Both workers are safe to run **in multiple copies** — they use
transactional row-claiming. If a single transcode worker can't keep up,
start more:

    sudo systemctl start fedivid-worker-transcode@2.service

(with a templated unit), or `docker compose up -d --scale worker-transcode=3`.

The web process is single-host-safe with hypnotoad's worker pool. To
scale across hosts, put a load balancer in front and point multiple
hypnotoad instances at the same Postgres.

---

## 5. Security checklist

Before exposing the instance publicly, verify:

- [ ] `FEDIVID_SESSION_SECRET` and `FEDIVID_ADMIN_SECRET` are unique
      random values, not the dev defaults.
- [ ] `FEDIVID_DATABASE_URL` uses a non-superuser role with a strong
      password.
- [ ] `FEDIVID_ALLOW_INSECURE_FETCH=0` (prod).
- [ ] `FEDIVID_ALLOW_SIGNUP=0` unless you intend public signup.
- [ ] The Postgres port is not exposed to the internet.
- [ ] Firewall allows only 22 (SSH), 80, and 443.
- [ ] TLS is terminated by a trusted certificate. Let's Encrypt is fine.
- [ ] Backups run and are stored off-site.
- [ ] NTP is active on the host.
- [ ] The uploads directory is not directly served by nginx or Caddy;
      all access goes through the app.
- [ ] `instances/prod.env` is not world-readable (`chmod 600`).
