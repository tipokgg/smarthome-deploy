#!/usr/bin/env bash
# Подготовка /opt/smarthome на сервере (sudo ./setup.sh), можно запускать повторно.
# Ничего не запускает: первый запуск и таймер обновлений - вручную, см. README.
set -euo pipefail
cd "$(dirname "$0")"
[[ "$PWD" == /opt/smarthome ]] || { echo "репозиторий должен лежать в /opt/smarthome" >&2; exit 1; }

# бэкенд в контейнере работает от uid 1000
install -d -o 1000 -g 1000 data backups backups/nightly backups/pre-update
install -d -m 700 -o 1000 -g 1000 config
install -d -m 700 state
[[ -f .env ]] || { cp .env.example .env; chmod 600 .env; echo "создан .env из шаблона"; }
[[ -f config/application.yml ]] || echo "нужно положить секреты бэкенда в config/application.yml"

install -m 644 systemd/*.service systemd/*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now smarthome-backup.timer
echo "готово; таймер обновлений: systemctl enable --now smarthome-update.timer"
