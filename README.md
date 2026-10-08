# smarthome-deploy

Запуск умного дома на домашнем сервере (Ubuntu Server, Docker Compose) и автообновление.

- `smarthome-backend` и `smarthome-frontend` на push в `main` собирают образы и кладут их в GHCR
  (`ghcr.io/tipokgg/smarthome-*`, теги `main` и `sha-<коммит>`).
- На сервере таймер `smarthome-update.timer` раз в 2 минуты запускает `scripts/update.sh`. Если у тега `main` новый образ,
  скрипт переключает на него сервис и ждёт healthcheck. Перед обновлением бэкенда он делает копию базы.
  Новая версия не поднялась: скрипт откатывает образ и базу, а сломанный образ запоминает в `state/failed` и больше не ставит.
- Какие образы запущены, записано в `.env` (`BACKEND_IMAGE`, `FRONTEND_IMAGE`, по digest). После перезагрузки
  поднимется ровно то, что там записано.
- Входящих подключений к серверу не нужно, от GitHub ему нужен только токен на чтение пакетов.

```
/opt/smarthome/            этот репозиторий
  compose.yml
  .env                     запущенные образы, настройки обновления, Telegram (не в git)
  config/application.yml   секреты бэкенда (не в git)
  config/router_ed25519    ключ для SSH к роутеру OpenWrt (мониторинг сети) и его known_hosts (не в git)
  data/smarthome.db        база SQLite (не в git)
  backups/nightly          ночные копии, 30 штук
  backups/pre-update       копии перед обновлением бэкенда, 10 штук
  state/                   блокировка и список сломанных образов
```

## Первая установка

1. Docker из официального репозитория (не snap), плюс sqlite3 и git:

   ```bash
   sudo apt update && sudo apt install -y ca-certificates curl sqlite3 git
   sudo install -m 0755 -d /etc/apt/keyrings
   sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
   echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list
   sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
   ```

2. Часовой пояс сервера (время в копиях и журналах): `sudo timedatectl set-timezone Europe/Moscow`.

3. Вход в GHCR. Нужен classic token с правом `read:packages`: fine-grained токены GHCR не поддерживает.
   Скрипт обновления работает от root, поэтому входить тоже от root:

   ```bash
   sudo docker login ghcr.io -u tipokgg
   ```

4. Репозиторий в `/opt/smarthome` и подготовка папок и таймеров. Сам `setup.sh` ничего не запускает:

   ```bash
   sudo git clone https://github.com/tipokgg/smarthome-deploy.git /opt/smarthome
   cd /opt/smarthome && sudo ./setup.sh
   ```

5. Секреты: `config/application.yml` с Мака (`~/smarthome/backend/config/application.yml`) положить в
   `/opt/smarthome/config/` и выставить `sudo chown 1000:1000 config/application.yml && sudo chmod 600 config/application.yml`.
   При желании вписать в `.env` бота для уведомлений: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`.

6. Мониторинг сети: ключ для SSH к роутеру OpenWrt в `config/router_ed25519` и `config/router_known_hosts`,
   скрипт на роутере — см. `router/README.md`. Без них вкладка «Сеть» работает, но без состояния роутера.

## Переезд с Мака

Два бэкенда одновременно запускать нельзя: оба станут опрашивать Haier Evo (облако отвечает 429 и может заблокировать
аккаунт) и Яндекс, а два «Умных климата» начнут спорить за термостат. Поэтому порядок такой:

1. Остановить бэкенд на Маке.
2. Снять копию базы на Маке: `sqlite3 ~/smarthome/backend/smarthome.db ".backup /tmp/smarthome.db"`,
   скопировать её на сервер в `/opt/smarthome/data/smarthome.db`, затем `sudo chown 1000:1000 data/smarthome.db`.
3. Запустить и дождаться healthcheck: `sudo docker compose up -d --wait`.
4. Проверить интерфейс на `http://<сервер>/`.
5. Включить автообновление: `sudo systemctl enable --now smarthome-update.timer`.

## Каждый день

| Что | Команда (в `/opt/smarthome`) |
|---|---|
| состояние | `sudo docker compose ps` |
| логи бэкенда | `sudo docker compose logs -f --tail 200 backend` |
| журнал обновлений | `journalctl -u smarthome-update -n 50` |
| запустить проверку обновлений сейчас | `sudo systemctl start smarthome-update` |
| копия базы сейчас | `sudo scripts/backup.sh nightly` |
| Swagger | `http://<сервер>/swagger-ui.html` |

**Ручной откат.** Поставить в `.env` `AUTO_UPDATE=0` и записать в `BACKEND_IMAGE` нужную версию, например
`ghcr.io/tipokgg/smarthome-backend:sha-78e09c2`. Затем `sudo docker compose up -d --wait backend`. Если новая версия
успела накатить миграции, сначала восстановить базу (ниже). Вернуться на автообновление: `AUTO_UPDATE=1`.

**Восстановить базу из копии.**

```bash
sudo docker compose stop backend
sudo rm -f data/smarthome.db-journal
gunzip -c backups/nightly/smarthome-<дата>.db.gz | sudo tee data/smarthome.db > /dev/null
sudo chown 1000:1000 data/smarthome.db
sudo docker compose up -d --wait backend
```

**Обновить сам этот репозиторий** (compose, скрипты): `sudo git pull`, затем `sudo docker compose up -d --wait`.
Если менялись юниты systemd, ещё `sudo ./setup.sh`.

## Что дальше

- Копии базы за пределами сервера (restic в облако или на NAS): сейчас они лежат только на нём самом.
- Удалённый доступ через Tailscale, без проброса портов: у бэкенда нет авторизации, а он управляет котлом.
- Zigbee2MQTT, Mosquitto и Postgres добавить сервисами в `compose.yml`, USB-стик пробросить через `devices: /dev/serial/by-id/...`.
