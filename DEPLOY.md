# Выкладка KTTF в прод

Как подключить купленный сервер и как идёт выкладка дальше. Требования к серверу — [SERVER-REQUIREMENTS.md](SERVER-REQUIREMENTS.md).

## Как устроено

```
push в main kttf-back ──► CI: lint, typecheck, test ──► образы kttf-api, kttf-migrate ──┐
push в main kttf-front ─► CI: lint, typecheck, test ──► образ kttf-web ─────────────────┤
                                                       ghcr.io/goats-web-studio/*:sha-…  │
                                                                                         ▼
                                     kttf-infra / Deploy (по SSH) ──► deploy/deploy.sh на сервере
                                                                       pull → миграции → up → проверка
                                                                       не поднялось — откат на прежние теги
```

- Образы собираются в GitHub Actions под `linux/amd64`, а не на сервере: сборка съела бы память работающего сайта.
- Тег образа — `sha-<7 знаков коммита>`, плюс плавающий `main`. У бэкенда и фронтенда теги свои: `API_TAG` и `WEB_TAG` в `.env` сервера.
- Пока сервер не подключён (нет секрета `DEPLOY_HOST`), шаг выкладки пропускается с пометкой. CI остаётся зелёным, образы копятся в GHCR.

На сервере:

```
/opt/kttf/
  kttf-infra/          # этот репозиторий, git clone
    .env               # секреты и теги, права 600, только здесь
    .deploy/           # history.log выкладок, lock
  backups/             # ночные копии: db-*.dump, media-*.tar.gz, backup.log
```

## Подключение сервера

### 1. DNS

В кабинете PS.kz, где домен kttf.kz, в управлении DNS добавить:

```
kttf.kz       A   <IP сервера>
www.kttf.kz   A   <IP сервера>
```

Проверка: `dig +short kttf.kz` показывает IP. Записи можно добавить заранее: сертификат Caddy получит, как только DNS начнёт смотреть на сервер.

### 2. Подготовка сервера

Зайти на сервер пользователем с sudo (`ubuntu@<IP>`).

Сначала на своей машине сделать ключ выкладки для GitHub Actions:

```
ssh-keygen -t ed25519 -N '' -C kttf-deploy -f ~/.ssh/kttf_deploy
cat ~/.ssh/kttf_deploy.pub      # понадобится ниже
```

На сервере:

```
curl -fsSL https://raw.githubusercontent.com/goats-web-studio/kttf-infra/main/deploy/bootstrap.sh \
  | sudo bash -s -- --deploy-key "<содержимое kttf_deploy.pub>"
```

Скрипт ставит Docker и Compose, swap, ufw (открыты 22, 80, 443), fail2ban и автообновления безопасности. Ещё он заводит пользователя `deploy`, клонирует репозиторий в `/opt/kttf/kttf-infra`, создаёт `.env` со свежими секретами и ставит ночные копии в cron. Повторный запуск безопасен.

**Сохранить `.env` в менеджер паролей:** `sudo cat /opt/kttf/kttf-infra/.env`.

Когда вход по ключам проверен, закрыть вход по паролю и под root:

```
sudo bash /opt/kttf/kttf-infra/deploy/bootstrap.sh --harden-ssh
```

### 3. Секреты GitHub

Лучше на уровне организации `goats-web-studio` (Settings → Secrets and variables → Actions), с доступом для репозиториев kttf-back, kttf-front и kttf-infra:

| Секрет | Значение |
| --- | --- |
| `DEPLOY_HOST` | IP сервера |
| `DEPLOY_USER` | `deploy` |
| `DEPLOY_SSH_KEY` | содержимое `~/.ssh/kttf_deploy` (закрытый ключ) |
| `DEPLOY_KNOWN_HOSTS` | вывод `ssh-keyscan -t ed25519 <IP>` |

То же через `gh`:

```
for repo in kttf-back kttf-front kttf-infra; do
  gh secret set DEPLOY_HOST        -R goats-web-studio/$repo -b '<IP>'
  gh secret set DEPLOY_USER        -R goats-web-studio/$repo -b 'deploy'
  gh secret set DEPLOY_SSH_KEY     -R goats-web-studio/$repo < ~/.ssh/kttf_deploy
  ssh-keyscan -t ed25519 <IP> 2>/dev/null | gh secret set DEPLOY_KNOWN_HOSTS -R goats-web-studio/$repo
done
```

### 4. Доступ к образам

После первого прогона CI в организации появятся пакеты `kttf-api`, `kttf-migrate` и `kttf-web`. Репозитории публичные, поэтому проще сделать публичными и пакеты: Packages → пакет → Package settings → Change visibility → Public. Тогда серверу вход в GHCR не нужен.

Если пакеты остаются приватными, в `.env` сервера указать `GHCR_USER` и `GHCR_TOKEN` (classic token с правом `read:packages`).

### 5. Первая выкладка

Actions → **Deploy** в kttf-infra → Run workflow, теги оставить пустыми: возьмутся `main` из `.env`. Или на сервере:

```
sudo -u deploy /opt/kttf/kttf-infra/deploy/deploy.sh
```

Миграции накатываются сами (`kttf-migrate`). Проверка: `https://kttf.kz` открывается, `https://kttf.kz/api/v1/health` отвечает.

### 6. Администратор

Зарегистрироваться на сайте, затем на сервере:

```
cd /opt/kttf/kttf-infra
docker compose exec kttf-postgres psql -U kttf -d kttf \
  -c "UPDATE \"User\" SET \"isAdmin\" = true WHERE login = '<логин>';"
```

## Каждый день

- **Выкладка сама:** push в `main` kttf-back или kttf-front → через несколько минут на проде.
- **Вручную или откат:** Actions → Deploy → указать `api_tag` или `web_tag` (например, прежний `sha-…` из `.deploy/history.log`).
- **Журналы:** `cd /opt/kttf/kttf-infra && docker compose logs -f kttf-api`.
- **Grafana и MinIO** наружу не открыты, только через SSH-туннель: `ssh -L 3001:127.0.0.1:3001 deploy@<IP>` → `http://localhost:3001`.

## Резервные копии

`deploy/backup.sh` каждую ночь в 03:30: дамп PostgreSQL (`pg_dump`, формат custom) и архив файлов MinIO. Хранятся `BACKUP_KEEP_DAYS` дней (14) в `/opt/kttf/backups`.

**Копия на том же диске от потери сервера не спасает.** Нужно хранилище вне сервера, в РК: адрес для rsync указать в `BACKUP_RSYNC_TARGET` в `.env`. Другой вариант — снимки VPS в панели PS.kz.

Восстановление базы, проверить до запуска:

```
docker compose exec -T kttf-postgres pg_restore -U kttf -d kttf --clean --if-exists < /opt/kttf/backups/db-<дата>.dump
```

Восстановление файлов:

```
docker run --rm -v kttf-minio-data:/data -v /opt/kttf/backups:/backup alpine \
  sh -c 'cd /data && tar xzf /backup/media-<дата>.tar.gz'
```
