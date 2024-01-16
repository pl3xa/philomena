#! /bin/bash

# 1p
export AGE_PUBKEY="age1nryzn8phcyhz93ddc6n0mlh5t3ju0t0d220zuzspuz9s726kgaxsps229d"
export FNAME="$(date +%s).sql.zst.age"

echo "[Postgres] password:"
docker compose run postgres pg_dump -U postgres -h postgres -d philomena_dev | zstd | age -r $AGE_PUBKEY > $FNAME
echo "uploading to gdrive shared drive GS backups"
rclone --config rclone.conf copy $FNAME gdrive: --drive-upload-cutoff 1000T
