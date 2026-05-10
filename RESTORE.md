# Restore guide — Philomena / Plexabooru

This file is bundled with each `backupWithVolumes.sh` run. One backup run = one
folder in the gdrive remote, named with the Unix-epoch timestamp `${TS}`. All
artifacts share that timestamp prefix:

```
gdrive:${TS}/
  ${TS}.sql.zst.age                   pg_dump of philomena_dev (canonical)
  ${TS}.postgres_data.tar.zst.age     raw /var/lib/postgresql/data (live tar, fallback)
  ${TS}.opensearch_data.tar.zst.age   OpenSearch data dir
  ${TS}.caddy_data.tar.zst.age        Caddy state (ACME certs)
  ${TS}.s3_data.tar.zst.age           declared in compose, currently unused
  ${TS}.RESTORE.md                    this file
```

`docker-compose.yml` is in git (no longer in backup). Secrets live in 1Password
Environment `ybro633rooejcx33nnfex64zs4` and are pulled into a local `.env` by
`bin/sync-env`; `docker compose` reads `.env` natively.

All `.age` artifacts are encrypted to age recipient
`age1nryzn8phcyhz93ddc6n0mlh5t3ju0t0d220zuzspuz9s726kgaxsps229d`. The matching
private key is in 1Password — ask the user for the keyfile; do not attempt to
fetch it yourself.

## What is NOT in this backup

A restore is only complete if these external resources still exist. They are
referenced by `docker-compose.yml` (in git) and the 1Password Environment, but
the data / configuration lives outside the host:

- **1Password Service Account token** — required by `bin/sync-env` to pull the
  Environment into `.env`. Stored at `~/.config/op/service-account-token`
  (mode 600) on the host. Save a copy alongside the age key in your personal
  1Password vault. Token loss = stack cannot start until a new Service Account
  is provisioned (the Environment itself survives — only the token needs
  replacing). The Environment id is `ybro633rooejcx33nnfex64zs4`.
- **`op` CLI (beta)** — `~/.local/bin/op` v2.35.0-beta.01 or later (the
  `op environment` subcommand is beta-only). See
  <https://app-updates.agilebits.com/product_history/CLI2> for the latest beta;
  download the linux_amd64 zip from
  `https://cache.agilebits.com/dist/1P/op2/pkg/<version>/op_linux_amd64_<version>.zip`
  and unpack into `~/.local/bin/`.
- **Cloudflare R2 bucket `booru-judge-sh`** — holds every uploaded image,
  avatar, advert, badge, and tag image. Postgres only stores filenames /
  metadata; without R2, the gallery is broken. R2 is the source of truth for
  blobs. See `S3_HOST` / `AWS_ACCESS_KEY_ID` in `.env` after sync-env runs.
- **Cloudflare Tunnel** — the `cloudflared` service uses `TUNNEL_TOKEN` from
  the Environment. The tunnel itself (ingress rules, hostnames) is configured
  in the Cloudflare dashboard. If the tunnel was deleted, recreate it and
  update `TUNNEL_TOKEN` in 1Password Environment `ybro633rooejcx33nnfex64zs4`.
- **DNS** — `booru.plexa.dev` and `boorucdn.plexa.dev` must resolve through
  Cloudflare to the tunnel.
- **SES SMTP** — credentials in the 1Password Environment; the SES identity
  must still be verified on the AWS side.
- **rclone.conf** — gitignored, NOT in this backup. Needed to run *future*
  backups, not to restore. Keep a copy alongside the age key.

## Decrypting

```bash
# Single file
age -d -i age-key.txt 1700000000.sql.zst.age | zstd -d > 1700000000.sql

# Whole bundle from one backup run
mkdir restore && cd restore
rclone --config rclone.conf copy gdrive:1700000000/ .
for f in 1700000000.*.age; do
  age -d -i ../age-key.txt "$f" > "${f%.age}"
done
```

## Clean-host restore (from a fresh git clone + one backup folder)

Assumes Docker + docker compose, age, zstd, rclone are installed, and the R2
bucket / Cloudflare Tunnel / DNS still exist.

```bash
# 1) Clone source. The git remote 'origin' is the deploy target;
#    'derp' tracks derpibooru/philomena upstream.
git clone <origin-url> philomena && cd philomena

# 2) Pull the backup folder and decrypt
mkdir -p /tmp/restore && cd /tmp/restore
rclone --config ~/rclone.conf copy gdrive:1700000000/ .
for f in 1700000000.*.age; do
  age -d -i ~/age-key.txt "$f" > "${f%.age}"
done
cd -

# 3) Install op CLI (beta) and restore the 1Password Service Account token.
#    Get the latest beta version from https://app-updates.agilebits.com/product_history/CLI2
mkdir -p ~/.local/bin
# Download op_linux_amd64_<version>.zip from cache.agilebits.com and unzip into ~/.local/bin/
mkdir -p ~/.config/op && chmod 700 ~/.config/op
# Paste the service account token (saved in 1Password personal vault) into:
printf 'ops_...' > ~/.config/op/service-account-token
chmod 600 ~/.config/op/service-account-token

# 4) Pull secrets into .env (do this BEFORE bringing services up).
./bin/sync-env

# 5) Bring up postgres on a clean volume and load the SQL dump
docker compose up -d postgres
docker compose exec postgres pg_isready -U postgres
docker compose exec -T postgres \
  psql -U postgres -c "CREATE DATABASE philomena_dev;" || true
cat /tmp/restore/1700000000.sql \
  | docker compose exec -T postgres \
      psql -U postgres -d philomena_dev

# 6) Restore opensearch + caddy data
docker compose stop opensearch web
docker volume rm philomena_opensearch_data philomena_caddy_data || true
docker volume create philomena_opensearch_data
docker volume create philomena_caddy_data
docker run --rm -i -v philomena_opensearch_data:/data alpine \
  tar -xf - -C /data < /tmp/restore/1700000000.opensearch_data.tar
docker run --rm -i -v philomena_caddy_data:/data alpine \
  tar -xf - -C /data < /tmp/restore/1700000000.caddy_data.tar

# 7) Start everything; the app/web Dockerfiles build inside their containers
docker compose up -d

# 8) First-time release build inside the app container (post-receive normally
#    handles this on git push). Required after a clean clone.
docker compose exec app sh -c 'mix deps.get && \
  npm install --prefix ./assets && \
  npm run deploy --prefix ./assets && \
  mix phx.digest && \
  mix release --overwrite'

# 9) Sanity checks
docker compose ps
docker compose exec postgres psql -U postgres -d philomena_dev \
  -c "SELECT COUNT(*) FROM schema_migrations;"   # should match pre-backup
docker compose exec opensearch curl -s localhost:9200/_cluster/health
#    status 'yellow' is normal for single-node OpenSearch
```

If OpenSearch was unrestorable or stale, rebuild the indexes from postgres:

```bash
docker compose exec app mix philomena.reindex_all
```

## Postgres-only restore (most common path)

```bash
./bin/sync-env   # ensure .env is populated before any compose command
docker compose down
docker volume rm philomena_postgres_data   # destructive; confirm with user first
docker compose up -d postgres
docker compose exec postgres pg_isready -U postgres
age -d -i age-key.txt 1700000000.sql.zst.age | zstd -d \
  | docker compose exec -T postgres \
      psql -U postgres -d philomena_dev
docker compose up -d
```

## Raw volume restore (when SQL dump is unavailable)

Prefer the SQL path for postgres — the volume tar is taken live and can be
page-torn. Use this for opensearch/caddy/s3, or for postgres only as a last
resort.

```bash
docker compose stop <service-using-volume>
docker volume rm philomena_<name> || true
docker volume create philomena_<name>
age -d -i age-key.txt 1700000000.<name>.tar.zst.age | zstd -d \
  | docker run --rm -i -v philomena_<name>:/data alpine \
      tar -xf - -C /data
docker compose up -d
```

## Notes for an agent doing the restore

- Confirm with the user before `docker volume rm` — destructive.
- The age private key and the 1Password Service Account token are not in this
  backup. Both live in the user's personal 1Password vault — ask before
  attempting recovery.
- If the host is being rebuilt, install `op` (beta) and run `./bin/sync-env`
  BEFORE any `docker compose` command — the stack reads from `.env`.
- After step 8 the app may still need a manual restart of any external app
  instances managed by `post-receive`. See the `post-receive` script in the
  repo for the deploy flow used on the production host.
- If only the database is corrupted, run the postgres-only path — do not
  touch the other volumes.
- Caddy data is optional; missing it just forces a fresh ACME issuance on
  next start.
