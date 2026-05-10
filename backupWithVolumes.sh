#! /bin/bash
# Full backup: postgres SQL dump + raw docker data volumes.
# Each artifact is zstd-compressed and age-encrypted, then uploaded with rclone.
# See RESTORE.md (bundled per run) for how to restore.
#
# Self-execs under `op run --environment=<id>` so that rclone picks up its
# RCLONE_CONFIG_GDRIVE_* variables and pg_dump gets PGPASSWORD from the
# 1Password Environment. No rclone.conf is needed.

set -euo pipefail

OP_ENV_ID="ybro633rooejcx33nnfex64zs4"
OP_BIN="${OP_BIN:-$HOME/.local/bin/op}"

# Re-exec under op run on first entry. Sentinel prevents infinite recursion.
if [[ -z "${_OP_RUN_LOADED:-}" ]]; then
  if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
    TOKEN_FILE="${OP_TOKEN_FILE:-$HOME/.config/op/service-account-token}"
    if [[ -r "$TOKEN_FILE" ]]; then
      OP_SERVICE_ACCOUNT_TOKEN="$(< "$TOKEN_FILE")"
      export OP_SERVICE_ACCOUNT_TOKEN
    else
      echo "error: OP_SERVICE_ACCOUNT_TOKEN unset and $TOKEN_FILE not readable" >&2
      exit 1
    fi
  fi
  export _OP_RUN_LOADED=1
  exec "$OP_BIN" run --environment="$OP_ENV_ID" --no-masking -- "$0" "$@"
fi

export AGE_PUBKEY="age1nryzn8phcyhz93ddc6n0mlh5t3ju0t0d220zuzspuz9s726kgaxsps229d"
TS="$(date +%s)"

# Compose project name used as the volume prefix (defaults to dir name).
PROJECT="${COMPOSE_PROJECT_NAME:-philomena}"

# Data volumes worth backing up. App build/deps caches are deliberately excluded.
VOLUMES=(postgres_data opensearch_data caddy_data s3_data)

# Prefer the user-local rclone v1.74+; falls back to system rclone if absent.
RCLONE="${RCLONE:-$HOME/.local/bin/rclone}"
[[ -x "$RCLONE" ]] || RCLONE=rclone

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# Stage artifacts in /tmp so the repo dir stays clean. Cleaned on any exit.
WORK_DIR="$(mktemp -d -t philomena-backup-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
echo "staging artifacts in $WORK_DIR"

encrypt_to() {
  age -r "$AGE_PUBKEY" > "$1"
}

echo "[1/3] postgres pg_dump -> ${TS}.sql.zst.age"
docker compose exec -T postgres \
  pg_dump -U postgres -d philomena_dev \
  | zstd \
  | encrypt_to "$WORK_DIR/${TS}.sql.zst.age"

echo "[2/3] tar docker volumes (live)"
for vol in "${VOLUMES[@]}"; do
  full="${PROJECT}_${vol}"
  out="${TS}.${vol}.tar.zst.age"
  echo "  - ${full} -> ${out}"
  docker run --rm -v "${full}:/data:ro" alpine \
    tar -cf - -C /data . \
    | zstd \
    | encrypt_to "$WORK_DIR/$out"
done

echo "[3/3] bundle RESTORE.md and upload to gdrive:${TS}/"
cp "$REPO_DIR/RESTORE.md" "$WORK_DIR/${TS}.RESTORE.md"

# One folder per backup run, named with the timestamp prefix.
for f in "$WORK_DIR/${TS}".*; do
  echo "  uploading $(basename "$f") -> gdrive:${TS}/"
  "$RCLONE" --config /dev/null copy "$f" "gdrive:${TS}/" --drive-upload-cutoff 1000T
done

echo "done. artifacts uploaded under gdrive:${TS}/"
