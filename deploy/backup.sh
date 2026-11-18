#!/usr/bin/env bash
# Ночная резервная копия KTTF: дамп PostgreSQL и архив файлов MinIO.
# Ставится в cron пользователя deploy (bootstrap.sh). Старше BACKUP_KEEP_DAYS
# дней — удаляются. BACKUP_RSYNC_TARGET задан — копия уходит и туда: копия
# на том же диске от потери сервера не спасает.
set -euo pipefail

cd "$(dirname "$0")/.."
env_get() { grep -E "^$1=" .env | tail -1 | cut -d= -f2-; }

dir="$(env_get BACKUP_DIR)"; dir="${dir:-/opt/kttf/backups}"
keep="$(env_get BACKUP_KEEP_DAYS)"; keep="${keep:-14}"
target="$(env_get BACKUP_RSYNC_TARGET)"
user="$(env_get POSTGRES_USER)"
db="$(env_get POSTGRES_DB)"
stamp="$(date +%Y-%m-%d_%H%M)"

mkdir -p "$dir"

# Сначала во временный файл: оборванный дамп не должен выглядеть готовым.
docker exec kttf-postgres pg_dump -U "$user" -d "$db" --format=custom --no-owner \
  > "$dir/.db-$stamp.dump.part"
mv "$dir/.db-$stamp.dump.part" "$dir/db-$stamp.dump"

docker run --rm -v kttf-minio-data:/data:ro -v "$dir":/backup alpine \
  tar czf "/backup/.media-$stamp.tar.gz.part" -C /data .
mv "$dir/.media-$stamp.tar.gz.part" "$dir/media-$stamp.tar.gz"

find "$dir" -maxdepth 1 -type f \( -name 'db-*.dump' -o -name 'media-*.tar.gz' \) -mtime "+$keep" -delete

if [[ -n "$target" ]]; then
  rsync -a --delete --include='db-*.dump' --include='media-*.tar.gz' --exclude='*' "$dir"/ "$target"/
fi

echo "$(date -Is) backup ok: db-$stamp.dump media-$stamp.tar.gz"
