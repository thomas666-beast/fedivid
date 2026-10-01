# Instance configuration

Each instance is described by one `.env` file in this directory.
The file is read by `script/start_instance.sh`, `script/run_workers.sh`,
and any manual `set -a; source instances/X.env; set +a` invocation.

## Fields

| Variable | Purpose |
|---|---|
| `FEDIVID_INSTANCE_NAME` | Site name shown in the top bar, page titles, RSS. |
| `FEDIVID_INSTANCE_DESCRIPTION` | One-line description shown on `/about`. |
| `FEDIVID_INSTANCE_CONTACT` | Admin contact (email or URL) shown on `/about`. |
| `FEDIVID_INSTANCE_RULES` | Rules shown on `/about`. Separate with `\|`. |
| `FEDIVID_INSTANCE_CATEGORIES` | Suggested categories on upload. Separate with `\|`. |
| `FEDIVID_INSTANCE_BANNER` | Optional banner image URL for the login page. |
| `FEDIVID_SCHEME` | `http` for dev, `https` in production. |
| `FEDIVID_DOMAIN` | Host (and optional port) that clients connect to. |
| `FEDIVID_BASE_URL` | Full origin. Usually `$SCHEME://$DOMAIN`. |
| `FEDIVID_LISTEN` | Address the app binds to, e.g. `http://127.0.0.1:3000`. |
| `FEDIVID_DATABASE_URL` | Postgres connection string. |
| `FEDIVID_UPLOAD_DIR` | Directory for uploaded videos, HLS, avatars. |
| `FEDIVID_SESSION_SECRET` | HMAC key for session cookies. Change in production. |
| `FEDIVID_ADMIN_SECRET` | Token required to create users and access `/admin`. |
| `FEDIVID_ALLOW_SIGNUP` | `1` to allow public signup, `0` for invite-only. |
| `FEDIVID_ALLOW_INSECURE_FETCH` | `1` to allow HTTP fetches (dev only). |
| `FEDIVID_RATE_LIMIT_DISABLED` | `1` to bypass rate limits (dev/tests only). |

## Adding an instance

    cp instances/local.env instances/mine.env
    # edit the fields
    createdb -U postgres fedivid_mine
    set -a; source instances/mine.env; set +a
    carton exec -- script/migrate
    ./script/start_instance.sh mine

## Running multiple instances locally

Useful for testing federation end-to-end. Each instance needs:

- Its own `.env` file with distinct `FEDIVID_DOMAIN`, `FEDIVID_LISTEN`, `FEDIVID_DATABASE_URL`, `FEDIVID_UPLOAD_DIR`
- Its own database
- Its own web process and worker pool

Three terminals for web + three for workers is a lot. `script/run_workers.sh` runs all three workers for one instance in a single terminal, so:

    ./script/start_instance.sh local     # terminal 1
    ./script/start_instance.sh peer1     # terminal 2

    ./script/run_workers.sh local        # terminal 3
    ./script/run_workers.sh peer1        # terminal 4

Then follow `@user@localhost:3001` from `@user@localhost:3000` via `/explore` to test live federation.
