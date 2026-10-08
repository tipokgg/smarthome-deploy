# Роутер OpenWrt для мониторинга сети

Канал провайдера и туннель podkop/sing-box умный дом проверяет сам, с сервера (вкладка «Сеть»). С роутера ему нужно только
то, что видно изнутри: uptime, память, conntrack, sing-box, WAN, события сторожа podkop. Это отдаёт по SSH
`smarthome-router.sh` — ничего не меняет, команды `stats` и `capture` (снимок при сбое туннеля в `/tmp/podkop-fail`).

Сторож podkop (`/etc/podkop-watchdog.sh` в cron роутера) остаётся на роутере: он чинит туннель и без сервера.

## Установка

1. Скрипт на роутер и в список файлов, которые переживают обновление прошивки:

   ```bash
   scp -O router/smarthome-router.sh root@192.168.1.1:/etc/smarthome-router.sh
   ssh root@192.168.1.1 'chmod +x /etc/smarthome-router.sh; grep -q smarthome-router /etc/sysupgrade.conf || echo /etc/smarthome-router.sh >> /etc/sysupgrade.conf'
   ```

2. Ключ сервера (на сервере, от uid 1000 — от него работает бэкенд) и ключ роутера для проверки, что отвечает именно он:

   ```bash
   cd /opt/smarthome
   sudo -u '#1000' ssh-keygen -q -t ed25519 -N '' -C smarthome-network-monitor -f config/router_ed25519
   ssh-keyscan -t ed25519 192.168.1.1 | sudo -u '#1000' tee config/router_known_hosts
   ```

3. Ключ на роутер, только для этого скрипта:

   ```bash
   echo "command=\"/etc/smarthome-router.sh\",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty $(cat config/router_ed25519.pub)" \
     | ssh root@192.168.1.1 'cat >> /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys'
   ```

Ограничение ключа работает, только когда у root на роутере есть пароль: без пароля dropbear пускает любого без ключа.

Проверка с сервера: `sudo -u '#1000' ssh -i config/router_ed25519 -o UserKnownHostsFile=config/router_known_hosts root@192.168.1.1 /etc/smarthome-router.sh stats`.
