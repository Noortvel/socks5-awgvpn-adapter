#!/bin/bash
set -e

CONFIG_FILE="/etc/amneziawg/awg0.conf"
SOCKS_PID=""
WATCHDOG_PID=""
DNS_KEEPALIVE_PID=""

# === Graceful shutdown ===
cleanup() {
    echo "🛑 Получен сигнал завершения, выполняю очистку..."
    # Читаем актуальный PID из файла (watchdog мог перезапустить 3proxy)
    SOCKS_PID=$(cat /tmp/3proxy.pid 2>/dev/null || echo "$SOCKS_PID")
    if [ -n "$SOCKS_PID" ] && kill -0 "$SOCKS_PID" 2>/dev/null; then
        kill "$SOCKS_PID" 2>/dev/null || true
    fi
    if [ -n "$WATCHDOG_PID" ] && kill -0 "$WATCHDOG_PID" 2>/dev/null; then
        kill "$WATCHDOG_PID" 2>/dev/null || true
    fi
    if [ -n "$DNSMASQ_PID" ] && kill -0 "$DNSMASQ_PID" 2>/dev/null; then
        kill "$DNSMASQ_PID" 2>/dev/null || true
    fi
    if [ -n "$DNS_KEEPALIVE_PID" ] && kill -0 "$DNS_KEEPALIVE_PID" 2>/dev/null; then
        kill "$DNS_KEEPALIVE_PID" 2>/dev/null || true
    fi
    awg-quick down "$CONFIG_FILE" 2>/dev/null || true
    echo "✅ Очистка завершена."
    exit 0
}
trap cleanup SIGTERM SIGINT SIGQUIT

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Ошибка: Конфигурационный файл $CONFIG_FILE не найден."
    echo "Смонтируйте ваш .conf файл в /etc/amneziawg/awg0.conf"
    exit 1
fi

# === BBR congestion control ===
# NOTE: BBR must be loaded on the HOST (e.g., `modprobe tcp_bbr` or in /etc/modules-load.d/).
# The SYS_MODULE capability was intentionally removed for security.
# modprobe here is a best-effort attempt that will fail gracefully if BBR is already loaded on the host.
echo "⚙️  Загрузка модулей ядра..."
modprobe tcp_bbr 2>/dev/null || true

# BBR требует fq qdisc для корректного pacing.
# net.core.default_qdisc — глобальный параметр, не namespaced, Docker не разрешает через sysctls.
# Пытаемся установить из контейнера (best-effort), если не выйдет — пользователь должен задать на хосте.
sysctl -w net.core.default_qdisc=fq 2>/dev/null || echo "⚠️  Не удалось установить fq qdisc (нужно на хосте: sysctl -w net.core.default_qdisc=fq)"

# Увеличиваем лимиты socket буферов (не namespaced — нельзя через docker-compose sysctls)
# Позволяют TCP auto-tuning расти до 12MB для заполнения BDP на высокоскоростных VPN
sysctl -w net.core.rmem_max=12582912 2>/dev/null || true
sysctl -w net.core.wmem_max=12582912 2>/dev/null || true

# Проверяем, какой congestion control активен (установлен через docker-compose sysctls)
CC=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "unknown")
echo "✅ TCP Congestion Control: $CC"
echo "✅ TCP MTU Probing: $(cat /proc/sys/net/ipv4/tcp_mtu_probing 2>/dev/null || echo '?')"
echo "✅ TCP Fast Open: $(cat /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null || echo '?')"

# Инициализируем openresolv
if command -v resolvconf &>/dev/null; then
    resolvconf -u 2>/dev/null || true
fi

echo "🔌 Подключение к AmneziaVPN..."
if ! awg-quick up "$CONFIG_FILE"; then
    echo "❌ Ошибка: Не удалось поднять VPN-туннель (awg-quick up failed)."
    exit 1
fi

if ip link show awg0 > /dev/null 2>&1; then
    echo "✅ Интерфейс awg0 успешно поднят."
else
    echo "❌ Ошибка: Интерфейс awg0 не поднялся."
    exit 1
fi

# === Tunnel warmup: ждём WG handshake + тестовый DNS через VPN ===
# Проблема: первый пакет через туннель может буферизоваться до завершения WG handshake,
# что приводит к медленному первому запросу или его дропу.
# Решение: проверяем наличие handshake (PersistentKeepalive мог уже его сделать),
# затем выполняем тестовый DNS через VPN — это реальный триггер handshake.
echo "🔥 Прогрев VPN-туннеля..."

# Быстрая проверка: был ли уже handshake (PersistentKeepalive=25 мог его сделать)
for i in 1 2 3; do
    LAST_HS=$(awg show latest-handshakes 2>/dev/null | awk '/awg0/{print $2}')
    NOW=$(date +%s)
    if [ -n "$LAST_HS" ] && [ "$LAST_HS" -gt 0 ] && [ $((NOW - LAST_HS)) -lt 30 ]; then
        echo "   WG handshake уже есть (${i}с)"
        break
    fi
    sleep 1
done

# Тестовый DNS-запрос через VPN — это реальный триггер WG handshake
WARMUP_DNS=$(grep '^nameserver' /etc/resolv.conf | head -1 | awk '{print $2}')
for i in 1 2 3; do
    if timeout 10 nslookup one.one.one.one "$WARMUP_DNS" >/dev/null 2>&1; then
        echo "✅ VPN-туннель прогрет (DNS через VPN работает, попытка $i)"
        break
    fi
    echo "   Попытка прогрева $i не удалась, retry..."
    sleep 2
done

# Убеждаемся что DNS настроен через VPN-туннель
if ! grep -q '^nameserver' /etc/resolv.conf 2>/dev/null; then
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 1.0.0.1" >> /etc/resolv.conf
    echo "options single-request timeout:3 attempts:3" >> /etc/resolv.conf
    echo "🌐 DNS настроен вручную через VPN (1.1.1.1, 1.0.0.1)"
fi

# === DNS-кеш через dnsmasq ===
# Сохраняем upstream DNS (полученные от VPN), запускаем dnsmasq на 127.0.0.1
# и направляем resolv.conf на него — повторные DNS-запросы кешируются

# Функция запуска dnsmasq (переиспользуется watchdog при краше)
start_dnsmasq() {
    dnsmasq \
        --no-daemon \
        --listen-address=127.0.0.1 \
        --port=53 \
        $SERVER_OPTS \
        --cache-size=10000 \
        --min-cache-ttl=300 \
        --dns-forward-max=1000 \
        --no-negcache \
        --no-resolv \
        --no-hosts \
        --log-facility=- \
        -q \
        --fast-dns-retry=500 \
        --all-servers \
        &
    DNSMASQ_PID=$!
}

UPSTREAM_DNS=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | head -2 | tr '\n' ' ' | sed 's/ $//')
if [ -n "$UPSTREAM_DNS" ] && command -v dnsmasq &>/dev/null; then
    echo "🗄️  Запуск DNS-кеша (dnsmasq), upstream: $UPSTREAM_DNS"
    SERVER_OPTS=""
    for ns in $UPSTREAM_DNS; do
        SERVER_OPTS="$SERVER_OPTS --server=$ns"
    done
    start_dnsmasq
    sleep 0.5
    if kill -0 "$DNSMASQ_PID" 2>/dev/null; then
        echo "nameserver 127.0.0.1" > /etc/resolv.conf
        echo "options single-request timeout:3 attempts:3" >> /etc/resolv.conf
        echo "✅ DNS-кеш активен (127.0.0.1 → $UPSTREAM_DNS)"

        # Prefetch: заполняем DNS-кеш популярными доменами,
        # чтобы первый запрос клиента не ждал холодного DNS через VPN
        echo "🔥 Предзагрузка DNS-кеша..."
        for domain in ifconfig.me one.one.one.one cloudflare.com google.com; do
            nslookup "$domain" 127.0.0.1 >/dev/null 2>&1 || true
        done
        echo "✅ DNS-кеш предзагружен"
    else
        echo "⚠️  dnsmasq не запустился, DNS без кеша"
        DNSMASQ_PID=""
    fi
else
    DNSMASQ_PID=""
fi

SOCKS_PORT=${SOCKS_PORT:-1080}
SOCKS_USER=${SOCKS_USER:-}
SOCKS_PASS=${SOCKS_PASS:-}
PROXY_CONF="/tmp/3proxy.cfg"
SOCKS_PID_FILE="/tmp/3proxy.pid"

# Читаем MTU из конфига для расчёта MSS (maxseg = MTU - 40 IP+TCP)
MTU_VALUE=$(grep -i '^MTU' "$CONFIG_FILE" 2>/dev/null | awk '{print $NF}' | tr -d '\r')
MTU_VALUE=${MTU_VALUE:-1280}
MSS_VALUE=$((MTU_VALUE - 40))
echo "📐 MTU: $MTU_VALUE, MSS (maxseg): $MSS_VALUE"

# === DNS keepalive: поддержание DNS-кеша в тепле ===
# Проблема: после idle периода DNS-кеш dnsmasq пустеет, первый запрос клиента
# ждёт холодного DNS через VPN. Решение: фоновый процесс каждые 2 минуты
# резолвит популярные домены, поддерживая кеш в тепле и туннель активным.
(
    while true; do
        sleep 120
        for domain in ifconfig.me cloudflare.com google.com; do
            nslookup "$domain" 127.0.0.1 >/dev/null 2>&1 || true
        done
    done
) &
DNS_KEEPALIVE_PID=$!

# === Watchdog: мониторинг VPN-туннеля + прокси ===
(
    WD_COUNT=0
    while true; do
        sleep 15
        WD_COUNT=$((WD_COUNT + 1))

        # Проверка 1: существует ли интерфейс
        if ! ip link show awg0 > /dev/null 2>&1; then
            echo "⚠️  Watchdog: интерфейс awg0 пропал, переподключение..."
            awg-quick down "$CONFIG_FILE" 2>/dev/null || true
            if awg-quick up "$CONFIG_FILE" 2>/dev/null; then
                echo "✅ Watchdog: VPN-туннель успешно восстановлен."
            else
                echo "❌ Watchdog: не удалось восстановить VPN-туннель."
            fi
            continue
        fi

        # Проверка 2: свежесть WireGuard handshake (>180с = туннель мёртв)
        LAST_HS=$(awg show latest-handshakes 2>/dev/null | awk '/awg0/{print $2}')
        NOW=$(date +%s)
        if [ -n "$LAST_HS" ] && [ "$LAST_HS" -gt 0 ] && [ $((NOW - LAST_HS)) -gt 180 ]; then
            echo "⚠️  Watchdog: последний handshake был >180с назад ($((NOW - LAST_HS))с), перезапуск туннеля..."
            awg-quick down "$CONFIG_FILE" 2>/dev/null || true
            sleep 2
            if awg-quick up "$CONFIG_FILE" 2>/dev/null; then
                echo "✅ Watchdog: VPN-туннель перезапущен."
            else
                echo "❌ Watchdog: не удалось перезапустить VPN-туннель."
            fi
            continue
        fi

        # Проверка 3: DNS-связность через VPN (каждые 60с = 4 итерации)
        # Проверяем что DNS-резолвинг через VPN туннель работает.
        # Это ловит ситуацию когда WG handshake свежий, но
        # DNS через VPN не отвечает (туннель "мёртв" для данных).
        if [ $((WD_COUNT % 4)) -eq 0 ]; then
            if ! timeout 5 nslookup one.one.one.one 127.0.0.1 >/dev/null 2>&1; then
                # Проверяем: dnsmasq упал?
                if [ -n "$DNSMASQ_PID" ] && ! kill -0 "$DNSMASQ_PID" 2>/dev/null; then
                    echo "⚠️  Watchdog: dnsmasq упал, перезапуск..."
                    start_dnsmasq
                    sleep 0.5
                    if kill -0 "$DNSMASQ_PID" 2>/dev/null; then
                        echo "✅ Watchdog: dnsmasq перезапущен (PID: $DNSMASQ_PID)"
                    else
                        echo "❌ Watchdog: не удалось перезапустить dnsmasq"
                    fi
                else
                    echo "⚠️  Watchdog: DNS через VPN не отвечает, прогрев туннеля..."
                    # Прямой запрос к upstream VPN DNS для триггера WG handshake
                    for _ns in $UPSTREAM_DNS; do
                        timeout 5 nslookup one.one.one.one "$_ns" >/dev/null 2>&1 || true
                    done
                fi
            fi
        fi

        # Проверка 4: работает ли SOCKS5 прокси (TCP connect)
        if ! timeout 5 bash -c "echo >/dev/tcp/127.0.0.1/$SOCKS_PORT" 2>/dev/null; then
            echo "⚠️  Watchdog: SOCKS5 прокси не отвечает, диагностика..."
            echo "   OOM kills: $(dmesg 2>/dev/null | grep -c 'Out of memory' || echo '?')"
            echo "   Память: $(free -m 2>/dev/null | awk '/Mem:/{printf "used=%dMB free=%dMB", $3, $4}' 2>/dev/null || echo '?')"
            echo "   FD count: $(ls /proc/$(cat "$SOCKS_PID_FILE" 2>/dev/null || echo 1)/fd 2>/dev/null | wc -l)"
            OLD_PID=$(cat "$SOCKS_PID_FILE" 2>/dev/null || echo "")
            if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
                kill "$OLD_PID" 2>/dev/null || true
            fi
            sleep 1
            3proxy "$PROXY_CONF" &
            NEW_PID=$!
            echo "$NEW_PID" > "$SOCKS_PID_FILE"
            echo "✅ Watchdog: 3proxy перезапущен (PID: $NEW_PID)."
        fi
    done
) &
WATCHDOG_PID=$!

# === Генерация конфигурации 3proxy ===
PROXY_DNS=$(grep '^nameserver' /etc/resolv.conf | head -1 | awk '{print $2}')

{
    echo "# DNS"
    echo "nserver $PROXY_DNS"
    echo "nscache 65535"
    echo "nscache6 65535"
    echo ""
    echo "# Логирование в stdout (docker logs)"
    echo "log"
    echo ""
    echo "# Таймауты (позиционные, в секундах)"
    echo "# Формат: BYTE_SHORT BYTE_LONG STRING_SHORT STRING_LONG CONN_SHORT CONN_LONG DNS CHAIN CONNECT CONNECTBACK"
    echo "# Дефолт: 1 5 30 60 180 1800 15 60 15 5"
    echo "# Оптимизировано для VPN-туннеля (50-200ms RTT):"
    echo "#   BYTE_S=2 BYTE_L=10 — запас на джиттер туннеля при SOCKS-хэндшейке"
    echo "#   STRING_L=180 — запас на медленный начальный поток через VPN"
    echo "#   DNS=15 — увеличен: WG rekey (до 5с) + DNS через VPN (до 10с)"
    echo "#   CONNECT=30 — TCP+TLS через VPN туннель может занимать 5-15с"
    echo "#   CONN_L=3600 — длинные SSH/WS-соединения не должны обрываться через 30мин"
    echo "timeouts 2 10 60 180 300 3600 15 60 30 5"
    echo ""
    echo "# Лимит одновременных соединений"
    echo "maxconn 500"
    echo ""
    echo "# MSS clamping для VPN-туннеля (MTU $MTU_VALUE - 40 IP+TCP = $MSS_VALUE)"
    echo "# Предотвращает PMTU black holes при общении с удалёнными серверами"
    echo "maxseg $MSS_VALUE"
    echo ""
    echo "# Размер стека потоков (добавка к дефолту, рекомендовано man 3proxy)"
    echo "stacksize 65536"
    echo ""
    if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
        echo "# Аутентификация"
        echo "users $SOCKS_USER:CL:$SOCKS_PASS"
        echo "auth strong"
        echo "allow $SOCKS_USER"
    else
        echo "auth none"
    fi
    echo ""
    echo "# SOCKS5 прокси с TCP-оптимизациями для VPN-туннеля"
    echo "# -oc/-os: TCP_NODELAY (отключить Nagle — меньше задержка мелких пакетов)"
    echo "#          SO_KEEPALIVE (детект мёртвых соединений через TCP keepalive)"
    echo "#          TCP_QUICKACK (немедленные ACK — меньше задержка через VPN)"
    echo "socks -p$SOCKS_PORT -olSO_REUSEADDR -ocTCP_NODELAY,SO_KEEPALIVE,TCP_QUICKACK -osTCP_NODELAY,SO_KEEPALIVE,TCP_QUICKACK"
} > "$PROXY_CONF"

echo "🧦 Запуск SOCKS5 прокси (3proxy) на порту $SOCKS_PORT..."

if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
    echo "🔒 Авторизация SOCKS5: Включена (Пользователь: $SOCKS_USER)"
else
    echo "🔓 Авторизация SOCKS5: Отключена"
fi

3proxy "$PROXY_CONF" &
SOCKS_PID=$!
echo "$SOCKS_PID" > "$SOCKS_PID_FILE"

wait -n
