#!/usr/bin/env bash
# Копия вне дома (таймер smarthome-offsite.timer, 04:00): restic в Yandex Object Storage, репозиторий <бакет>/smarthome.
# База - свежая согласованная копия (.backup) без gzip: restic сжимает сам и не грузит повторно неизменённые блоки.
# Плюс то, без чего восстановление долгое: zigbee2mqtt (ключ сети и устройства), сертификат tv-bridge, секреты
# (config/, .env, secrets/ - ключи VPN, секреты ESPHome, выгрузки настроек роутеров) и мелочи самого сервера: Tailscale,
# вход в GHCR, SSH. Портал СНТ (/opt/snt) копирует себя сам.
# Ключи доступа и пароль репозитория - в /etc/restic (не в git), см. README «Копии вне дома».
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
trap 'notify "копия вне дома не удалась (строка $LINENO), см. journalctl -u smarthome-offsite"' ERR

set -a
# shellcheck source=/dev/null
source /etc/restic/offsite.env
set +a
# под systemd нет $HOME: без кэша restic каждый раз заново качает индекс из хранилища
export RESTIC_CACHE_DIR=${RESTIC_CACHE_DIR:-/var/cache/restic}
export RESTIC_REPOSITORY="s3:https://storage.yandexcloud.net/${RESTIC_BUCKET}/smarthome"
restic cat config > /dev/null 2>&1 || restic init

# каталог бэкенда (uid 1000): sqlite3 работает от его имени, а в state/ (root, 700) ему не войти
STAGE=backups/offsite
rm -rf "$STAGE"
install -d -m 700 -o 1000 -g 1000 "$STAGE"
# от имени бэкенда (uid 1000): служебные файлы sqlite3 рядом с базой бэкенд сможет писать
setpriv --reuid=1000 --regid=1000 --clear-groups sqlite3 -bail data/smarthome.db ".backup '$STAGE/smarthome.db'"

# пути - абсолютные: в снимке они так и лежат (/opt/smarthome/..., /root/...), относительные restic кладёт в корень
paths=("$PWD/$STAGE/smarthome.db")
for p in data/zigbee2mqtt data/tv-bridge config .env secrets \
  /var/lib/tailscale/tailscaled.state /root/.docker/config.json /root/.ssh /etc/ssh/sshd_config.d \
  /home/tipok/.ssh/authorized_keys /etc/netplan; do
  [[ "$p" == /* ]] || p="$PWD/$p"
  [[ -e "$p" ]] && paths+=("$p")
done
restic backup --host smarthome --tag nightly --exclude "$PWD/data/zigbee2mqtt/log" "${paths[@]}"
restic forget --host smarthome --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune
# раз в месяц - прочитать часть данных из хранилища и сверить
if [[ $(date +%d) == 01 ]]; then
  restic check --read-data-subset=10%
fi
rm -rf "$STAGE"
