# smarthome-deploy

Запуск умного дома на домашнем сервере (Ubuntu Server, Docker Compose) и автообновление.

- `smarthome-backend` и `smarthome-frontend` на push в `main` собирают образы и кладут их в GHCR
  (`ghcr.io/tipokgg/smarthome-*`, теги `main` и `sha-<коммит>`). Репозиторий бэкенда собирает ещё и мост к телевизорам
  `smarthome-tv-bridge` (из папки `tv-bridge`).
- На сервере таймер `smarthome-update.timer` раз в 2 минуты запускает `scripts/update.sh`. Если у тега `main` новый образ,
  скрипт переключает на него сервис и ждёт healthcheck. Перед обновлением бэкенда он делает копию базы.
  Новая версия не поднялась: скрипт откатывает образ и базу, а сломанный образ запоминает в `state/failed` и больше не ставит.
- Какие образы запущены, записано в `.env` (`BACKEND_IMAGE`, `FRONTEND_IMAGE`, `TV_BRIDGE_IMAGE`, по digest). После перезагрузки
  поднимется ровно то, что там записано.
- Входящих подключений к серверу не нужно, от GitHub ему нужен только токен на чтение пакетов.

```
/opt/smarthome/            этот репозиторий
  compose.yml
  .env                     запущенные образы, настройки обновления, Telegram (не в git)
  config/application.yml   секреты бэкенда (не в git)
  config/router_ed25519    ключ для SSH к роутеру OpenWrt (мониторинг сети) и его known_hosts (не в git)
  data/smarthome.db        база SQLite (не в git)
  data/tv-bridge/          сертификат моста к телевизорам: его помнят сопряжённые ТВ (не в git)
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

## Телевизоры (tv-bridge)

Мост держит соединение с телевизорами Android TV по протоколу пульта Google TV (порты 6466/6467 телевизора), бэкенд ходит
к нему по `http://tv-bridge:8090`. Наружу порт не открыт. Какие телевизоры есть, задаёт бэкенд (`tv.devices`).

Подключить на уже работающем сервере (до этого моста не было):

```bash
cd /opt/smarthome && sudo git pull
sudo install -d -o 1000 -g 1000 data/tv-bridge
echo 'TV_BRIDGE_IMAGE=ghcr.io/tipokgg/smarthome-tv-bridge:main' | sudo tee -a .env
echo 'TV_BRIDGE_TRACK=ghcr.io/tipokgg/smarthome-tv-bridge:main' | sudo tee -a .env
sudo docker compose up -d --wait
```

Сопряжение — один раз на телевизор, на странице «ТВ»: «Сопрячь», телевизор показывает 6 символов, их ввести там же.
Сертификат лежит в `data/tv-bridge` (в ночные копии не попадает): если его потерять, сопрягать заново.
IP телевизора лучше закрепить на роутере: бэкенд знает телевизор по адресу из `tv.devices`.

## Камеры (go2rtc)

go2rtc забирает RTSP с камер и отдаёт видео странице «Камеры» по WebSocket через nginx фронта (`/camera/ws?src=<поток>`,
nginx пускает только имя потока). Наружу порт не открыт: API go2rtc без авторизации и умеет запускать команды.
Камеры и потоки — в `go2rtc.yaml` (в git, паролей там нет); имена потоков те же, что в `CAMERAS` фронтенда.
Образ закреплён на версии (`GO2RTC_IMAGE` в `.env` её меняет), `scripts/update.sh` его не обновляет.

Подключить на уже работающем сервере:

```bash
cd /opt/smarthome && sudo git pull
sudo docker compose up -d --wait
```

Камера двора (H.264 с 07.11.2026) портит параметры кодека в SDP, и напрямую браузер её не показывает. Поэтому go2rtc
пересобирает поток через ffmpeg без перекодирования (`exec:ffmpeg … -c copy`): ~1% ядра, только пока страница открыта.
ffmpeg запускается без изучения потока (`-analyzeduration 0`): иначе он теряет ключевой кадр начала подключения, а
следующий камера шлёт только через ~8,6 с (интервал в её настройках на это не влияет). Картинка — через ~2 с.
После правки `go2rtc.yaml` — `sudo docker compose restart go2rtc` (`up -d` изменения файла не замечает).
Если на камере включить пароль RTSP, адрес в `go2rtc.yaml` станет `rtsp://<логин>:<пароль>@…` — тогда этот файл
переезжает в `config/` (не в git) и монтируется оттуда.

## Газета (Gotenberg и принтер)

Утренняя газета собирается бэкендом в 06:30 (страница «Газета»). PDF печатает `gotenberg` — Chromium в контейнере:
он открывает страницу выпуска у бэкенда (`http://backend:8080/api/newspaper/<дата>`, шрифты — там же) и ходить может
только туда (`--chromium-allow-list`). Принтер Xerox Phaser 3020 (`192.168.10.28`, IPP) PDF не принимает: бэкенд
растрирует PDF в Apple Raster 600 dpi и отправляет заданием IPP. Образ закреплён на версии (`GOTENBERG_IMAGE` в `.env`),
`scripts/update.sh` его не обновляет. Автопечать после сборки — `NEWSPAPER_AUTO_PRINT=true` у бэкенда (по умолчанию
выключена), адрес принтера — `NEWSPAPER_PRINTER_URI`.

Подключить на уже работающем сервере:

```bash
cd /opt/smarthome && sudo git pull
sudo docker compose up -d --wait gotenberg
```

## Zigbee (zigbee2mqtt и Mosquitto)

Координатор — SMLIGHT SLZB-06P7U (CC2652P7, Z-Stack) на потолке кабинета 1 этажа, питание и сеть по PoE, `192.168.10.245`
(закреплён на роутере, MAC 90:da:72:f2:32:a0). zigbee2mqtt
ходит к нему по TCP (`tcp://<координатор>:6638`) и публикует устройства в Mosquitto (`zigbee2mqtt/…`), бэкенд слушает
брокер (`ZIGBEE_MQTT_URL`). Брокер наружу не открыт и без паролей. Веб-интерфейс zigbee2mqtt (сопряжение, карта сети) —
`http://<сервер>:8099`, токен — `ZIGBEE2MQTT_FRONTEND_TOKEN`. Оба сервиса — в профиле `zigbee`: без
`COMPOSE_PROFILES=zigbee` в `.env` они не запускаются. Версии закреплены (`ZIGBEE2MQTT_IMAGE`, `MOSQUITTO_IMAGE`),
`scripts/update.sh` их не обновляет.

Настройки zigbee2mqtt — шаблон `zigbee2mqtt/configuration.yaml`; `setup.sh` кладёт его в `data/zigbee2mqtt/`, только
если там файла ещё нет. При первом запуске zigbee2mqtt создаёт ключ сети и PAN ID и пишет их в этот файл. Без
`data/zigbee2mqtt` все устройства придётся сопрягать заново, поэтому ночная копия (`scripts/backup.sh nightly`) кладёт
его архивом рядом с базой. Канал (25) выбирается один раз, до первого запуска: смена потом — переподключение устройств.

Координатор (веб-интерфейс `http://<координатор>/`): адрес закрепить на роутере, обновить обе прошивки (ядро и Zigbee),
режим — Zigbee Coordinator, подключение — Ethernet, Wi-Fi модуля выключить, пароль на веб-интерфейс.

Подключить на уже работающем сервере:

```bash
cd /opt/smarthome && sudo git pull && sudo ./setup.sh
# в .env: COMPOSE_PROFILES=zigbee, ZIGBEE_ADAPTER_HOST, ZIGBEE_MQTT_URL, ZIGBEE2MQTT_FRONTEND_TOKEN
sudo docker compose up -d --wait
```

`up -d` пересоздаст и бэкенд (у него новая переменная). Проверка: `sudo docker compose logs zigbee2mqtt` — «Zigbee2MQTT
started», в логах бэкенда — «Connected to MQTT broker».

## Каждый день

| Что | Команда (в `/opt/smarthome`) |
|---|---|
| состояние | `sudo docker compose ps` |
| логи бэкенда | `sudo docker compose logs -f --tail 200 backend` |
| логи моста к телевизорам | `sudo docker compose logs -f --tail 200 tv-bridge` |
| логи go2rtc (камеры) | `sudo docker compose logs -f --tail 200 go2rtc` |
| логи Gotenberg (PDF газеты) | `sudo docker compose logs -f --tail 200 gotenberg` |
| логи zigbee2mqtt | `sudo docker compose logs -f --tail 200 zigbee2mqtt` |
| что идёт по MQTT | `sudo docker compose exec mosquitto mosquitto_sub -v -t 'zigbee2mqtt/#'` |
| журнал обновлений | `journalctl -u smarthome-update -n 50` |
| запустить проверку обновлений сейчас | `sudo systemctl start smarthome-update` |
| копия базы сейчас | `sudo scripts/backup.sh nightly` |
| копия вне дома сейчас / журнал | `sudo systemctl start smarthome-offsite` / `journalctl -u smarthome-offsite -n 50` |
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

## Копии вне дома

`scripts/offsite.sh` (таймер `smarthome-offsite.timer`, 04:00): restic в Yandex Object Storage, репозиторий
`<бакет>/smarthome`. В копии — свежая согласованная копия базы (`.backup`, без gzip: restic сжимает сам и не грузит
повторно неизменённые блоки), `data/zigbee2mqtt` (без логов), `data/tv-bridge`, `config/` и `.env`. restic шифрует всё
до отправки. Хранится 7 ежедневных, 4 еженедельных и 12 ежемесячных копий; 1-го числа `restic check` читает 10% данных
из хранилища и сверяет. Сбой — в Telegram.

Ключи и пароль — общие для умного дома и портала СНТ (`/opt/snt`), в `/etc/restic` (только root, не в git):

```bash
sudo apt install -y restic
sudo install -d -m 700 /etc/restic
sudo sh -c 'umask 077; openssl rand -base64 33 > /etc/restic/password'   # сохранить ещё и в менеджер паролей!
sudo install -m 600 /dev/null /etc/restic/offsite.env && sudo nano /etc/restic/offsite.env
```

```
RESTIC_BUCKET=<имя бакета>
AWS_ACCESS_KEY_ID=<идентификатор статического ключа сервисного аккаунта>
AWS_SECRET_ACCESS_KEY=<секретный ключ>
AWS_DEFAULT_REGION=ru-central1
RESTIC_PASSWORD_FILE=/etc/restic/password
```

Без пароля репозитория копии не расшифровать: если сервер погибнет вместе с `/etc/restic/password`, копии бесполезны.
Бакет — класс «Стандартное» (первый 1 ГБ в месяц бесплатно), без публичного доступа и без версионирования;
сервисный аккаунт — с ролью `storage.editor` только на этот бакет.

Включить: `sudo ./setup.sh && sudo systemctl enable --now smarthome-offsite.timer`, первая копия — `sudo systemctl
start smarthome-offsite` (`journalctl -u smarthome-offsite`).

Восстановление (на любом сервере с restic и тем же `/etc/restic`):

```bash
set -a; source /etc/restic/offsite.env; set +a
export RESTIC_REPOSITORY=s3:https://storage.yandexcloud.net/$RESTIC_BUCKET/smarthome
restic snapshots
restic restore latest --target /tmp/smarthome-restore   # файлы - по исходным путям внутри /tmp/smarthome-restore
```

Затем при остановленном бэкенде — `state/offsite/smarthome.db` из копии в `data/smarthome.db`, `data/zigbee2mqtt`,
`data/tv-bridge`, `config/`, `.env` — на место, владелец — uid 1000.

## Что дальше

- Удалённый доступ через Tailscale, без проброса портов: у бэкенда нет авторизации, а он управляет котлом.
- Postgres сервисом в `compose.yml`.
