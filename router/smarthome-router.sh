#!/bin/sh
# Роутер OpenWrt (192.168.1.1) для мониторинга сети умного дома. Канал провайдера и туннель проверяет сам сервер,
# здесь только то, что видно лишь изнутри роутера. Сервер заходит по SSH ключом с принудительной командой
# (/etc/dropbear/authorized_keys, см. router/README.md), команда приходит в SSH_ORIGINAL_COMMAND:
#   stats    состояние роутера, sing-box и WAN построчно key=value, плюс свежие события самого роутера
#   capture  туннель не работает: снимок соединений, дамп трафика до VPS, лог sing-box и проверка независимым
#            экземпляром sing-box; наборы файлов - в /tmp/podkop-fail, последние 6
# Ничего не меняет в настройках; сторож podkop (/etc/podkop-watchdog.sh) работает сам по себе из cron.
CFG=/etc/sing-box/config.json
FAILDIR=/tmp/podkop-fail

vps_target() {
    jq -r '.outbounds[] | select(.tag == "main-out") | "\(.server) \(.server_port)"' "$CFG" 2>/dev/null | head -1
}

stats() {
    set -- $(vps_target)
    vps=$1; port=$2
    sb=$(pidof sing-box | awk '{print $1}')
    echo "uptime=$(cut -d. -f1 /proc/uptime)"
    echo "load=$(cut -d' ' -f1 /proc/loadavg)"
    echo "mem_available_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo)"
    echo "conntrack=$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null)"
    grep ^TCP: /proc/net/sockstat | awk '{print "tcp_inuse="$3; print "tcp_orphan="$5; print "tcp_tw="$7}'
    echo "orphan_msgs=$(dmesg | grep -c 'orphaned sockets')"
    echo "singbox_pid=$sb"
    [ -n "$sb" ] && echo "singbox_rss_kb=$(awk '/VmRSS/{print $2}' /proc/$sb/status 2>/dev/null)"
    /etc/init.d/podkop enabled && echo "podkop_enabled=true" || echo "podkop_enabled=false"
    echo "vps=$vps"
    echo "vps_port=$port"
    if [ -n "$vps" ]; then
        netstat -tn 2>/dev/null | awk -v p="$vps:$port" '$5 == p {n++; if ($6 == "ESTABLISHED") e++} END {print "vps_conn=" n+0; print "vps_conn_established=" e+0}'
    fi
    echo "wan_up=$(ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null)"
    echo "wan_ip=$(ip -4 addr show wan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1)"
    echo "gateway=$(ip route | awk '/^default/{print $3; exit}')"
    # события, которые пишет сам роутер: сторож podkop и переходы WAN из hotplug; сервер отбрасывает уже известные
    grep -h "СТОРОЖ" /root/podkop-events.log 2>/dev/null | tail -n 20 | sed 's/^/event=/'
    grep -h "СОБЫТИЕ" /root/isp-events.log 2>/dev/null | tail -n 20 | sed 's/^/event=/'
}

capture() {
    set -- $(vps_target)
    vps=$1; port=$2
    [ -n "$vps" ] || { echo "error=no main-out in $CFG"; exit 1; }
    tsf=$(date "+%Y%m%d-%H%M%S")
    mkdir -p "$FAILDIR"
    curl -s -m 5 http://192.168.1.1:9090/connections > "$FAILDIR/$tsf.conns.json" 2>/dev/null
    tpid=
    if command -v tcpdump >/dev/null; then
        tcpdump -ni wan -c 400 -w "$FAILDIR/$tsf.pcap" host "$vps" and port "$port" >/dev/null 2>&1 &
        tpid=$!
    fi
    # независимый экземпляр sing-box с тем же VLESS-outbound, socks на 127.0.0.1:1081: сломан ли сам outbound
    # или только основной экземпляр
    jq '{log:{level:"warn"},
         inbounds:[{type:"mixed",tag:"in",listen:"127.0.0.1",listen_port:1081}],
         outbounds:[(.outbounds[]|select(.tag=="main-out")),{type:"direct",tag:"direct"}],
         route:{final:"main-out"}}' "$CFG" > /tmp/sing-box-probe.json
    sing-box run -c /tmp/sing-box-probe.json >/tmp/sing-box-probe.log 2>&1 &
    ppid=$!
    sleep 2
    probe=$(curl -s -o /dev/null -m 10 -x socks5h://127.0.0.1:1081 -w "%{http_code}/%{time_total}" https://www.youtube.com/generate_204 2>/dev/null)
    kill $ppid 2>/dev/null
    sleep 3
    [ -n "$tpid" ] && kill $tpid 2>/dev/null
    logread | grep -E "sing-box|podkop" | tail -60 > "$FAILDIR/$tsf.singbox.log"
    cp /tmp/sing-box-probe.log "$FAILDIR/$tsf.probe.log" 2>/dev/null
    ls -t "$FAILDIR"/*.conns.json 2>/dev/null | tail -n +7 | while read f; do rm -f "${f%.conns.json}".*; done
    echo "files=$FAILDIR/$tsf.*"
    echo "probe=$probe"
    tail -n 5 "$FAILDIR/$tsf.singbox.log" | sed 's/^/log=/'
}

# сервер присылает полный путь и команду: так вызов работает и с принудительной командой ключа, и без неё
# (пока у root нет пароля, dropbear пускает без ключа, и тогда команда выполняется как есть)
cmd=${SSH_ORIGINAL_COMMAND:-$*}
case "${cmd##* }" in
    stats) stats ;;
    capture) capture ;;
    *) echo "usage: stats | capture" >&2; exit 2 ;;
esac
