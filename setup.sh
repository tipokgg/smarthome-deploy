#!/usr/bin/env bash
# Подготовка /opt/smarthome на сервере (sudo ./setup.sh), можно запускать повторно.
# Ничего не запускает: первый запуск и таймер обновлений - вручную, см. README.
set -euo pipefail
cd "$(dirname "$0")"
[[ "$PWD" == /opt/smarthome ]] || { echo "репозиторий должен лежать в /opt/smarthome" >&2; exit 1; }

# бэкенд и мост к телевизорам в контейнерах работают от uid 1000
install -d -o 1000 -g 1000 data data/tv-bridge data/zigbee2mqtt backups backups/nightly backups/pre-update
# Mosquitto в контейнере работает от своего пользователя mosquitto (uid 1883)
install -d -o 1883 -g 1883 data/mosquitto
# настройки zigbee2mqtt - только если их ещё нет: он переписывает файл сам, там ключ сети
[[ -f data/zigbee2mqtt/configuration.yaml ]] || install -m 600 -o 1000 -g 1000 zigbee2mqtt/configuration.yaml data/zigbee2mqtt/
# свои описания устройств - всегда из репозитория (подхватываются при перезапуске zigbee2mqtt); папку zigbee2mqtt
# пишет сам (симлинк node_modules, временные копии), поэтому копия, а не монтирование только для чтения
install -d -o 1000 -g 1000 data/zigbee2mqtt/external_converters
install -m 644 -o 1000 -g 1000 zigbee2mqtt/external_converters/*.mjs data/zigbee2mqtt/external_converters/
install -d -m 700 -o 1000 -g 1000 config
install -d -m 700 state secrets
[[ -f .env ]] || { cp .env.example .env; chmod 600 .env; echo "создан .env из шаблона"; }
[[ -f config/application.yml ]] || echo "нужно положить секреты бэкенда в config/application.yml"

install -m 644 systemd/*.service systemd/*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now smarthome-backup.timer
echo "готово; таймер обновлений: systemctl enable --now smarthome-update.timer"
