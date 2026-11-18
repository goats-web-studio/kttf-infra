#!/usr/bin/env bash
# Подготовка чистого сервера под KTTF — Ubuntu 24.04, запуск один раз:
#
#   curl -fsSL https://raw.githubusercontent.com/goats-web-studio/kttf-infra/main/deploy/bootstrap.sh \
#     | sudo bash -s -- --deploy-key "ssh-ed25519 AAAA... kttf-deploy"
#
# Повторный запуск безопасен: каждый шаг проверяет, сделан ли он.
#
# Что делает: Docker и Compose, swap, ufw (22, 80, 443), fail2ban,
# автообновления безопасности, пользователь deploy для выкладки из CI,
# /opt/kttf с репозиторием kttf-infra, .env со свежими секретами, ночные
# резервные копии. С --harden-ssh — вход только по ключам и без root.
set -euo pipefail

DEPLOY_USER=deploy
ROOT_DIR=/opt/kttf
INFRA_DIR="$ROOT_DIR/kttf-infra"
INFRA_REPO=https://github.com/goats-web-studio/kttf-infra.git
DEPLOY_KEY=""
HARDEN_SSH=0
SWAP_SIZE=2G

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deploy-key) DEPLOY_KEY="$2"; shift 2 ;;
    --harden-ssh) HARDEN_SSH=1; shift ;;
    --swap) SWAP_SIZE="$2"; shift 2 ;;
    *) echo "Неизвестный параметр: $1" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Запускать через sudo" >&2; exit 1; }

log() { printf '\n==> %s\n' "$*"; }

log "Пакеты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq ca-certificates curl git ufw fail2ban unattended-upgrades openssl rsync

log "Docker"
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091 # файл системы, есть на любой Ubuntu
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker
# Журналы контейнеров не съедают диск: ротация по 10 МБ, три файла.
if [[ ! -f /etc/docker/daemon.json ]]; then
  cat > /etc/docker/daemon.json <<'JSON'
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
JSON
  systemctl restart docker
fi

log "Swap $SWAP_SIZE"
if ! swapon --show | grep -q .; then
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

log "Файрвол: 22, 80, 443"
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

log "fail2ban и автообновления безопасности"
systemctl enable --now fail2ban
dpkg-reconfigure -f noninteractive unattended-upgrades

log "Пользователь $DEPLOY_USER"
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$DEPLOY_USER"
fi
usermod -aG docker "$DEPLOY_USER"
if [[ -n "$DEPLOY_KEY" ]]; then
  home="/home/$DEPLOY_USER"
  install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  grep -qF "$DEPLOY_KEY" "$home/.ssh/authorized_keys" || echo "$DEPLOY_KEY" >> "$home/.ssh/authorized_keys"
  chown "$DEPLOY_USER:$DEPLOY_USER" "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"
fi

log "Репозиторий $INFRA_DIR"
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$ROOT_DIR" "$ROOT_DIR/backups"
if [[ ! -d "$INFRA_DIR/.git" ]]; then
  sudo -u "$DEPLOY_USER" git clone "$INFRA_REPO" "$INFRA_DIR"
fi

log "Окружение .env"
if [[ ! -f "$INFRA_DIR/.env" ]]; then
  env_file="$INFRA_DIR/.env"
  cp "$INFRA_DIR/deploy/env.production.example" "$env_file"
  # Каждый секрет свой: 32 байта, только [a-f0-9] — без символов, которые
  # ломают строку подключения к базе.
  while grep -q '__GENERATE__' "$env_file"; do
    sed -i "0,/__GENERATE__/s//$(openssl rand -hex 32)/" "$env_file"
  done
  chown "$DEPLOY_USER:$DEPLOY_USER" "$env_file"
  chmod 600 "$env_file"
  echo "Создан $env_file — секреты только здесь, сохраните копию в менеджере паролей."
fi

log "Ночные резервные копии (03:30)"
cron_line="30 3 * * * $INFRA_DIR/deploy/backup.sh >> $ROOT_DIR/backups/backup.log 2>&1"
# На чистом сервере crontab пуст: crontab -l и grep -v без строк вернут 1,
# а с pipefail это обрывает скрипт. Пустой список — норма, не ошибка.
{ crontab -u "$DEPLOY_USER" -l 2>/dev/null | grep -vF 'deploy/backup.sh' || true; echo "$cron_line"; } \
  | crontab -u "$DEPLOY_USER" -

if [[ $HARDEN_SSH -eq 1 ]]; then
  log "SSH: только ключи, без root"
  cat > /etc/ssh/sshd_config.d/90-kttf.conf <<'CONF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
CONF
  sshd -t
  systemctl reload ssh
fi

log "Готово"
cat <<MSG
Дальше:
  1. DNS: A-записи kttf.kz и www.kttf.kz → IP этого сервера.
  2. GitHub: секреты DEPLOY_HOST, DEPLOY_USER=$DEPLOY_USER, DEPLOY_SSH_KEY, DEPLOY_KNOWN_HOSTS
     (kttf-infra/DEPLOY.md, шаг 3).
  3. Первая выкладка: Actions → Deploy в kttf-infra, или на сервере:
       sudo -u $DEPLOY_USER $INFRA_DIR/deploy/deploy.sh
MSG
