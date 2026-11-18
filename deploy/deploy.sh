#!/usr/bin/env bash
# Выкладка KTTF на сервере. Запускает пользователь deploy — из GitHub Actions
# (.github/workflows/deploy.yml) или руками:
#
#   deploy.sh                       # те же теги, что в .env, — перезапуск с обновлением
#   deploy.sh --api sha-1a2b3c4     # новая версия бэкенда
#   deploy.sh --web sha-5d6e7f8     # новая версия фронтенда
#
# Образы не собираются на сервере — только тянутся из GHCR (ADR-030: сборка
# съела бы память работающего сайта). Миграции накатывает kttf-migrate до
# старта API. Если новая версия не поднялась, теги возвращаются на прежние.
set -euo pipefail

cd "$(dirname "$0")/.."
ENV_FILE=.env
STATE_DIR=.deploy
HEALTH_TIMEOUT=180

API_TAG_NEW=""
WEB_TAG_NEW=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --api) API_TAG_NEW="$2"; shift 2 ;;
    --web) WEB_TAG_NEW="$2"; shift 2 ;;
    *) echo "Неизвестный параметр: $1" >&2; exit 2 ;;
  esac
done

[[ -f "$ENV_FILE" ]] || { echo "Нет $ENV_FILE — сначала deploy/bootstrap.sh" >&2; exit 1; }

log() { printf '\n==> %s\n' "$*"; }
env_get() { grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2-; }
env_set() {
  if grep -qE "^$1=" "$ENV_FILE"; then
    sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"
  else
    echo "$1=$2" >> "$ENV_FILE"
  fi
}
valid_tag() { [[ "$1" =~ ^[A-Za-z0-9_.-]{1,128}$ ]]; }

for tag in "$API_TAG_NEW" "$WEB_TAG_NEW"; do
  [[ -z "$tag" ]] || valid_tag "$tag" || { echo "Недопустимый тег: $tag" >&2; exit 2; }
done

# Одна выкладка за раз: две параллельные перепутали бы теги и откат.
mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
flock -n 9 || { echo "Уже идёт другая выкладка" >&2; exit 1; }

log "Конфигурация стека"
git pull --ff-only --quiet

API_TAG_OLD="$(env_get API_TAG)"
WEB_TAG_OLD="$(env_get WEB_TAG)"
[[ -z "$API_TAG_NEW" ]] || env_set API_TAG "$API_TAG_NEW"
[[ -z "$WEB_TAG_NEW" ]] || env_set WEB_TAG "$WEB_TAG_NEW"
echo "API: ${API_TAG_OLD:-—} → $(env_get API_TAG), фронт: ${WEB_TAG_OLD:-—} → $(env_get WEB_TAG)"

GHCR_USER="$(env_get GHCR_USER)"
GHCR_TOKEN="$(env_get GHCR_TOKEN)"
if [[ -n "$GHCR_USER" && -n "$GHCR_TOKEN" ]]; then
  printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null
fi

compose() { docker compose --env-file "$ENV_FILE" "$@"; }

wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT)) status
  while (( SECONDS < deadline )); do
    status="$(docker inspect -f '{{.State.Health.Status}}' kttf-api 2>/dev/null || echo missing)"
    [[ "$status" == healthy ]] && return 0
    sleep 3
  done
  echo "API не стал healthy за ${HEALTH_TIMEOUT} с (статус: $status)" >&2
  return 1
}

migrated() {
  local code
  code="$(docker inspect -f '{{.State.ExitCode}}' kttf-migrate 2>/dev/null || echo 1)"
  [[ "$code" == 0 ]] || { echo "Миграция завершилась с кодом $code" >&2; return 1; }
}

# Снаружи — через настоящий прокси. Пока DNS не смотрит на сервер, адрес
# подставляется локальный (--resolve), а сертификата ещё нет: тогда хватает
# ответа прокси по HTTP (редирект на HTTPS). Здоровье API уже проверено выше.
smoke() {
  local domain
  domain="$(env_get KTTF_DOMAIN)"
  curl -fsS --max-time 10 --resolve "$domain:443:127.0.0.1" "https://$domain/api/v1/health" >/dev/null \
    || curl -fsS --max-time 10 --resolve "$domain:80:127.0.0.1" -o /dev/null "http://$domain/api/v1/health"
}

up() {
  compose pull --quiet
  compose up -d --no-build --remove-orphans
  wait_healthy && migrated && smoke
}

log "Запуск"
if up; then
  printf '%s %s api=%s web=%s\n' "$(date -Is)" ok "$(env_get API_TAG)" "$(env_get WEB_TAG)" >> "$STATE_DIR/history.log"
  docker image prune -f >/dev/null
  log "Выложено: api=$(env_get API_TAG) web=$(env_get WEB_TAG)"
  exit 0
fi

log "Новая версия не поднялась — откат"
compose logs --tail 80 kttf-migrate kttf-api >&2 || true
[[ -z "$API_TAG_OLD" ]] || env_set API_TAG "$API_TAG_OLD"
[[ -z "$WEB_TAG_OLD" ]] || env_set WEB_TAG "$WEB_TAG_OLD"
printf '%s %s api=%s web=%s\n' "$(date -Is)" rollback "$API_TAG_NEW" "$WEB_TAG_NEW" >> "$STATE_DIR/history.log"
if up; then
  echo "Откат прошёл: api=$(env_get API_TAG) web=$(env_get WEB_TAG)" >&2
else
  echo "Откат тоже не поднялся — нужен человек: docker compose ps, docker compose logs" >&2
fi
exit 1
