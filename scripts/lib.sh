# Общее для скриптов: переменные из .env, журнал, уведомления

# без export: переменные окружения у Compose важнее .env, и он не увидел бы образ, записанный в .env через env_set
# shellcheck source=/dev/null
source .env

log() {
  echo "$*"
}

# notify <текст> - в журнал и, если настроен, в Telegram
notify() {
  log "$1"
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    curl -fsS -m 10 -o /dev/null "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=🏠 $1" || log "не удалось отправить уведомление в Telegram"
  fi
}

# env_set <ключ> <значение> - записать значение в .env
env_set() {
  if grep -q "^$1=" .env; then
    sed -i "s|^$1=.*|$1=$2|" .env
  else
    echo "$1=$2" >> .env
  fi
}

# revision <образ> - короткий хеш коммита, из которого собран образ, а без метки - начало digest или тег
revision() {
  local rev
  rev=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$1" 2> /dev/null || true)
  if [[ -n "$rev" && "$rev" != "<no value>" ]]; then
    echo "${rev:0:7}"
  else
    local ref=${1##*[:@]}
    echo "${ref:0:12}"
  fi
}
