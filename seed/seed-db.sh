#!/bin/sh
# Заливает демо-базу в пустой стек. Запускается контейнером kttf-seed до
# миграций: дамп несёт схему вместе с журналом Prisma, и kttf-migrate потом
# докатывает только то, что появилось после снимка.
#
# Непустую базу не трогает никогда — повторный `docker compose up` безопасен.
set -eu

if [ "${KTTF_DEMO_SEED:-0}" != "1" ]; then
  echo "Демо-данные выключены (KTTF_DEMO_SEED не 1)"
  exit 0
fi

if [ -n "$(psql -tAc "select to_regclass('public._prisma_migrations')")" ]; then
  echo "База уже заполнена, демо-данные не нужны"
  exit 0
fi

gunzip -c /seed/demo.sql.gz | psql -q -v ON_ERROR_STOP=1 >/dev/null
echo "Демо-данные залиты"
