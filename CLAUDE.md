# Philomena — Claude context

## Project overview

This is a customized Philomena deployment (Plexabooru / booru.plexa.dev). It is not a proper git fork of derpibooru/philomena but tracks it as an upstream reference for service versions and compose structure. The `derp` git remote points to derpibooru/philomena.

---

## Secrets & local environment

Runtime secrets are stored in **1Password Environment `ybro633rooejcx33nnfex64zs4`** and pulled to a gitignored `.env` by `bin/sync-env`. `docker-compose.yml` is committed in git with `${VAR}` interpolation for every secret; the .env file is the substitution source.

### Bringing the stack up

```bash
./bin/sync-env          # writes .env from the 1Password Environment
docker compose up -d
```

Re-run `./bin/sync-env` after a secret rotates in 1Password, then `docker compose up -d` again to apply.

### Required tools (host)

- **`~/.local/bin/op` v2.35.0-beta.01 or later** — beta build needed for `op environment` and `op run --environment`. Install: download the linux_amd64 zip from `https://cache.agilebits.com/dist/1P/op2/pkg/<version>/op_linux_amd64_<version>.zip` (latest beta listed at <https://app-updates.agilebits.com/product_history/CLI2>) and unzip into `~/.local/bin/`. Stable apt builds do not yet ship the Environments feature.
- **`~/.local/bin/rclone` v1.74.1+** — used by `backupWithVolumes.sh`. The script wraps itself in `op run --environment=…` so rclone picks up `RCLONE_CONFIG_GDRIVE_*` from 1Password automatically; **no `rclone.conf` is needed.**
- **`~/.config/op/service-account-token`** (mode 600) — Service Account token scoped to read the Environment. `bin/sync-env` and `backupWithVolumes.sh` both source this. Token loss = stack cannot start until a new Service Account is provisioned (the Environment itself survives).

### Recovery state to back up

The Service Account token and the age private key are the only off-host secrets needed to bring up a fresh deployment. Keep them in your personal 1Password vault — they are NOT in `backupWithVolumes.sh` output.

---

## Tracking & upgrades

### Source of truth for service versions

**derpibooru/philomena** (`derp` remote) is the canonical upstream for:
- Docker image versions (postgres, opensearch, valkey, s3proxy)
- `docker-compose.yml` structure and new services
- Elixir/Phoenix app changes to merge in


### How to check current upstream versions

```bash
# Fetch the live derpibooru compose file (requires gh auth)
~/.local/bin/gh api repos/derpibooru/philomena/contents/docker-compose.yml --jq '.content' | base64 -d

# Check if derpibooru added new docker services
~/.local/bin/gh api repos/derpibooru/philomena/contents/docker --jq '.[].name'

# See recent derpibooru commits
~/.local/bin/gh api repos/derpibooru/philomena/commits --jq '.[0:10][] | "\(.commit.author.date) \(.commit.message | split("\n")[0])"'
```

If `gh` is unavailable or unauthenticated, fall back to the unauthenticated GitHub API (rate-limited to 60 req/hr):

```bash
curl -s https://api.github.com/repos/derpibooru/philomena/contents/docker-compose.yml | python3 -c "import sys,json,base64; print(base64.b64decode(json.load(sys.stdin)['content']).decode())"
```

### Upgrade process

Before planning any upgrade, always re-pull the derpibooru compose as above and diff against the running stack:

```bash
docker compose ps --format "table {{.Name}}\t{{.Image}}"
```

**Postgres major version upgrade** (e.g. 17 → 18) requires dump/restore — cannot hot-swap the volume:

```bash
# 1. Dump while live
docker compose exec -T postgres pg_dump -U postgres philomena_dev > ~/philomena_dev_backup_$(date +%Y%m%d_%H%M%S).sql

# 2. Snapshot the old volume before destroying it
docker volume create postgres_data_backup
docker run --rm -v postgres_data:/from -v postgres_data_backup:/to alpine sh -c "cp -a /from/. /to/"

# 3. Destroy old volume, update image in docker-compose.yml, bring up postgres only
docker compose down
docker volume rm postgres_data
# (edit docker-compose.yml image version)
docker compose up -d postgres

# 4. Restore
docker compose exec postgres pg_isready -U postgres
cat ~/philomena_dev_backup_*.sql | docker compose exec -T postgres psql -U postgres -d philomena_dev

# 5. Verify — migration count and table count must match pre-upgrade
docker compose exec postgres psql -U postgres -d philomena_dev -c "SELECT COUNT(*) FROM schema_migrations;"

# 6. Bring everything up, then delete backup volume once confirmed healthy
docker compose up -d
docker volume rm postgres_data_backup
```

**Minor version upgrades** (opensearch patch, valkey, s3proxy) are safe in-place — just update the image tag in `docker-compose.yml` and `docker compose up -d`.

**Valkey** has no named volume in this compose, so it is always ephemeral — any version bump is safe.

### Health check baseline (as of 2026-04-13, derpibooru parity)

| Service | Image | Notes |
|---|---|---|
| postgres | `postgres:17.6-alpine` | 29 migrations, latest `20250507183410` |
| opensearch | `opensearchproject/opensearch:3.2.0` | Single-node; `yellow` cluster status is normal |
| valkey | `valkey/valkey:8.1.3-alpine` | Ephemeral |
| s3proxy | `andrewgaul/s3proxy:sha-9f66ef5` | |
| cloudflared | `cloudflare/cloudflared:latest` | Not in derpibooru upstream |

OpenSearch `yellow` is expected on a single-node deployment — replica shards have nowhere to be assigned. It is not an error.
