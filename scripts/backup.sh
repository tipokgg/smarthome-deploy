#!/usr/bin/env bash
# Копия базы SQLite (и раз в сутки - данных zigbee2mqtt): backup.sh [nightly|pre-update]. Печатает путь к копии базы.
# Работающий бэкенд не мешает: .backup делает согласованную копию.
set -euo pipefail
cd "$(dirname "$0")/.."

KIND=${1:-nightly}
case "$KIND" in
  nightly) KEEP=30 ;;
  pre-update) KEEP=10 ;;
  *) echo "неизвестный вид копии: $KIND" >&2; exit 1 ;;
esac

DB=data/smarthome.db
[[ -f "$DB" ]] || { echo "нет базы $DB" >&2; exit 1; }

DEST=backups/$KIND
install -d -o 1000 -g 1000 "$DEST"
OUT="$DEST/smarthome-$(date +%Y%m%d-%H%M%S).db"
# от имени бэкенда (uid 1000): если sqlite3 создаст служебный файл рядом с базой, бэкенд сможет его писать
setpriv --reuid=1000 --regid=1000 --clear-groups sqlite3 -bail "$DB" ".backup '$OUT'"
gzip "$OUT"

# старые копии этого вида
ls -1t "$DEST"/smarthome-*.db.gz | tail -n +$((KEEP + 1)) | xargs -r rm --

# zigbee2mqtt раз в сутки: ключ сети, база устройств и копия координатора - без них все устройства сопрягать заново.
# Файлы маленькие, копия идёт рядом с базой; путь не печатается - stdout читает scripts/update.sh
if [[ "$KIND" == nightly && -f data/zigbee2mqtt/configuration.yaml ]]; then
  tar -czf "$DEST/zigbee2mqtt-$(date +%Y%m%d-%H%M%S).tar.gz" -C data --exclude zigbee2mqtt/log zigbee2mqtt
  ls -1t "$DEST"/zigbee2mqtt-*.tar.gz | tail -n +$((KEEP + 1)) | xargs -r rm --
fi

echo "$OUT.gz"
