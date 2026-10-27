#!/bin/sh
# Докладывает в MinIO файлы демо-базы: логотипы клубов, фото тренеров и
# игроков, картинки форума, а если положены рядом — и фото каталога.
#
# Ключи файлов — UUID, поэтому копируется только недостающее, а уже
# загруженное через интерфейс не перезаписывается.
set -eu

if [ "${KTTF_DEMO_SEED:-0}" != "1" ]; then
  echo "Демо-файлы выключены (KTTF_DEMO_SEED не 1)"
  exit 0
fi

export MC_CONFIG_DIR=/tmp/.mc
mc alias set kttf "${MINIO_URL:-http://kttf-minio:9000}" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
mc mb --ignore-existing kttf/kttf-media >/dev/null
mc mirror --quiet /seed/media kttf/kttf-media >/dev/null
echo "Демо-файлы на месте"
