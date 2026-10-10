#!/usr/bin/env bash
# Установка и обновление сервера аккаунтов D20Hero на VPS (Ubuntu или Debian).
#
# Запуск на сервере под root:
#   curl -fsSL https://raw.githubusercontent.com/Nafarion/DND-Calc-public/main/server/install.sh | bash -s -- api.d20hero.ru https://d20hero.ru you@example.com
#
# (тот же скрипт лежит и на самом сайте: https://d20hero.ru/server/install.sh)
#
# Аргументы:
#   1. домен сервера аккаунтов (на него должна смотреть запись A);
#   2. адрес сайта — для ссылок в письмах и разрешённых источников запросов;
#   3. почта администратора — только при первой установке: для неё будет создан
#      вход в панель управления, пароль скрипт покажет в конце.
#
# Повторный запуск обновляет PocketBase, миграции и обработчики, данные не трогает.
#
# Капча «я не робот» (Яндекс SmartCaptcha) включается ключом сервера:
#   curl ... | SMARTCAPTCHA_SERVER_KEY=ключ bash -s -- api.d20hero.ru https://d20hero.ru
# Ключ сохраняется на сервере, при следующих обновлениях его можно не указывать.
#
# Сообщения из формы «Написать нам» лежат в панели управления (таблица feedback).
# Чтобы получать копию каждого на почту, укажите адрес один раз:
#   curl ... | FEEDBACK_EMAIL=you@example.com bash -s -- api.d20hero.ru https://d20hero.ru

set -euo pipefail

API_DOMAIN="${1:?Укажите домен сервера, например api.d20hero.ru}"
SITE_URL="${2:-https://d20hero.ru}"
ADMIN_EMAIL="${3:-}"
PB_VERSION="${PB_VERSION:-0.40.4}"

SITE_URL="${SITE_URL%/}"
SITE_HOST="${SITE_URL#*://}"
APP_DIR=/opt/dnd-calc-api
SERVICE=dnd-calc-api

say() { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Запустите скрипт от root (через sudo)." >&2
  exit 1
fi

say "Ставлю нужные пакеты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl unzip ca-certificates openssl >/dev/null

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) echo "Неизвестная архитектура процессора: $(uname -m)" >&2; exit 1 ;;
esac

say "Готовлю пользователя и папку $APP_DIR"
id -u pocketbase >/dev/null 2>&1 || useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin pocketbase
mkdir -p "$APP_DIR"
FRESH_INSTALL=0
[ -f "$APP_DIR/pb_data/data.db" ] || FRESH_INSTALL=1

say "Скачиваю PocketBase $PB_VERSION"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/pb.zip" \
  "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_${ARCH}.zip"
unzip -o -q "$TMP/pb.zip" pocketbase -d "$TMP"
install -m 0755 "$TMP/pocketbase" "$APP_DIR/pocketbase"

say "Скачиваю миграции"
# Сначала с сайта, а если у него ещё нет сертификата — из публичного репозитория сайта.
BUNDLE_FALLBACK="${BUNDLE_URL:-https://raw.githubusercontent.com/Nafarion/DND-Calc-public/main/server/bundle.tgz}"
if ! curl -fsL --max-time 30 -o "$TMP/bundle.tgz" "$SITE_URL/server/bundle.tgz" 2>/dev/null; then
  echo "    сайт пока недоступен по HTTPS — беру файлы из репозитория"
  curl -fsSL --max-time 60 -o "$TMP/bundle.tgz" "$BUNDLE_FALLBACK"
fi
tar -xzf "$TMP/bundle.tgz" -C "$TMP"
rm -rf "$APP_DIR/pb_migrations" "$APP_DIR/pb_hooks"
cp -r "$TMP/pb_migrations" "$APP_DIR/pb_migrations"
if [ -d "$TMP/pb_hooks" ]; then cp -r "$TMP/pb_hooks" "$APP_DIR/pb_hooks"; else mkdir -p "$APP_DIR/pb_hooks"; fi
chown -R pocketbase:pocketbase "$APP_DIR"

# Ключ шифрования настроек (в том числе пароля почты). Создаётся один раз:
# если его потерять или поменять, сохранённые настройки не прочитаются.
KEY_FILE="$APP_DIR/secret.env"
if [ ! -f "$KEY_FILE" ]; then
  say "Создаю ключ шифрования настроек"
  umask 077
  echo "PB_ENCRYPTION_KEY=$(openssl rand -hex 16)" >"$KEY_FILE"
  umask 022
fi
if [ -n "${SMARTCAPTCHA_SERVER_KEY:-}" ]; then
  say "Сохраняю ключ капчи"
  grep -v '^SMARTCAPTCHA_SERVER_KEY=' "$KEY_FILE" >"$KEY_FILE.new" || true
  echo "SMARTCAPTCHA_SERVER_KEY=${SMARTCAPTCHA_SERVER_KEY}" >>"$KEY_FILE.new"
  mv "$KEY_FILE.new" "$KEY_FILE"
fi
if [ -n "${FEEDBACK_EMAIL:-}" ]; then
  say "Сохраняю адрес для сообщений с сайта"
  grep -v '^FEEDBACK_EMAIL=' "$KEY_FILE" >"$KEY_FILE.new" || true
  echo "FEEDBACK_EMAIL=${FEEDBACK_EMAIL}" >>"$KEY_FILE.new"
  mv "$KEY_FILE.new" "$KEY_FILE"
fi
chown root:root "$KEY_FILE"
chmod 600 "$KEY_FILE"

say "Настраиваю службу $SERVICE"
ORIGINS="https://${SITE_HOST},https://www.${SITE_HOST},http://${SITE_HOST},http://www.${SITE_HOST}"
cat >"/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=D20Hero: сервер аккаунтов (PocketBase)
After=network-online.target
Wants=network-online.target

[Service]
User=pocketbase
Group=pocketbase
WorkingDirectory=${APP_DIR}
Environment=DND_SITE_URL=${SITE_URL}
Environment=DND_API_URL=https://${API_DOMAIN}
EnvironmentFile=${KEY_FILE}
# С доменом в аргументах PocketBase сам слушает порты 80 и 443
# и сам получает и продлевает сертификат Let's Encrypt.
ExecStart=${APP_DIR}/pocketbase serve ${API_DOMAIN} --dir=${APP_DIR}/pb_data --migrationsDir=${APP_DIR}/pb_migrations --hooksDir=${APP_DIR}/pb_hooks --hooksWatch=false --encryptionEnv=PB_ENCRYPTION_KEY --origins=${ORIGINS}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Restart=always
RestartSec=5
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  say "Открываю порты 80 и 443 в брандмауэре"
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
fi

systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1
systemctl restart "$SERVICE"
sleep 3

if ! systemctl is-active --quiet "$SERVICE"; then
  echo "Служба не запустилась. Последние строки журнала:" >&2
  journalctl -u "$SERVICE" -n 30 --no-pager >&2
  exit 1
fi

ADMIN_PASSWORD=""
if [ "$FRESH_INSTALL" -eq 1 ] && [ -n "$ADMIN_EMAIL" ]; then
  say "Создаю вход в панель управления для $ADMIN_EMAIL"
  ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
  # shellcheck disable=SC1090
  (set -a; . "$KEY_FILE"; set +a
   runuser -u pocketbase -- env PB_ENCRYPTION_KEY="$PB_ENCRYPTION_KEY" \
     "$APP_DIR/pocketbase" superuser upsert "$ADMIN_EMAIL" "$ADMIN_PASSWORD" \
     --dir="$APP_DIR/pb_data" --encryptionEnv=PB_ENCRYPTION_KEY >/dev/null)
fi

say "Проверяю, что сервер отвечает по https://${API_DOMAIN}"
HEALTHY=0
for _ in $(seq 1 20); do
  if curl -fsS --max-time 5 "https://${API_DOMAIN}/api/health" >/dev/null 2>&1; then
    HEALTHY=1
    break
  fi
  sleep 3
done

echo
echo "============================================================"
if [ "$HEALTHY" -eq 1 ]; then
  echo " Сервер работает: https://${API_DOMAIN}"
else
  echo " Служба запущена, но https://${API_DOMAIN} пока не отвечает."
  echo " Проверьте, что запись A для ${API_DOMAIN} указывает на этот сервер,"
  echo " и подождите несколько минут — сертификат выпускается при первом запросе."
fi
echo " Панель управления: https://${API_DOMAIN}/_/"
if [ -n "$ADMIN_PASSWORD" ]; then
  echo " Вход в панель:     ${ADMIN_EMAIL}"
  echo " Пароль:            ${ADMIN_PASSWORD}"
  echo " Сохраните пароль — больше он нигде не показывается."
fi
echo "============================================================"
