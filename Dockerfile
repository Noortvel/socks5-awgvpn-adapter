# ---- Stage 1a: Сборка amneziawg-go (нужен Go >= 1.24) ----
FROM golang:1.24-alpine AS awg-go-builder

RUN apk add --no-cache git make

RUN git clone --depth 1 --branch v0.2.17 https://github.com/amnezia-vpn/amneziawg-go.git && \
    cd amneziawg-go && \
    make

# ---- Stage 1b: Сборка amneziawg-tools + 3proxy ----
FROM alpine:3.23 AS awg-tools-builder

RUN apk add --no-cache \
    git \
    make \
    cmake \
    build-base \
    libmnl-dev

# Собираем amneziawg-tools
RUN git clone --depth 1 --branch v1.0.20260223 https://github.com/amnezia-vpn/amneziawg-tools.git && \
    cd amneziawg-tools/src && \
    make WITH_WGQUICK=yes && \
    make WITH_WGQUICK=yes DESTDIR=/out install

# Собираем 3proxy через CMake — гарантирует splice zero-copy (WITHSPLICE)
# Старый Makefile.Linux мог не включать splice, что снижает throughput streaming
# Патчим MAXSPLICE 64KB → 256KB: каждый splice chunk через pipe doubles syscalls,
# большие чанки = меньше syscalls при streaming (YouTube и т.п.)
RUN git clone --depth 1 --branch 0.9.6 https://github.com/3proxy/3proxy.git && \
    cd 3proxy && \
    sed -i 's/^#define MAXSPLICE .*/#define MAXSPLICE 262144/' src/sockmap.c && \
    grep -n 'MAXSPLICE' src/sockmap.c && \
    cmake -S . -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -D3PROXY_USE_SPLICE=ON \
      -D3PROXY_USE_OPENSSL=OFF \
      -D3PROXY_USE_PCRE2=OFF \
      -D3PROXY_USE_PAM=OFF && \
    cmake --build build -j$(nproc) && \
    install -Dm755 build/bin/3proxy /usr/local/bin/3proxy

# ---- Stage 2: Финальный образ ----
FROM alpine:3.23

RUN apk add --no-cache \
    bash \
    curl \
    iproute2 \
    iptables \
    openresolv \
    ca-certificates \
    kmod \
    dnsmasq \
    && mkdir -p /run/openresolv

# Копируем бинарник amneziawg-go
COPY --from=awg-go-builder /go/amneziawg-go/amneziawg-go /usr/bin/amneziawg-go

# Копируем ВСЕ файлы утилит из amneziawg-tools
COPY --from=awg-tools-builder /out/usr/bin/ /usr/bin/

# Копируем 3proxy
COPY --from=awg-tools-builder /usr/local/bin/3proxy /usr/bin/3proxy

# Делаем файлы исполняемыми
RUN chmod +x /usr/bin/amneziawg-go /usr/bin/awg /usr/bin/awg-quick /usr/bin/3proxy && \
    command -v amneziawg-go && command -v awg-quick && command -v 3proxy

# === Патчим awg-quick для работы в контейнере ===
# Заменяем вызов sysctl для src_valid_mark на команду true
RUN sed -i '/src_valid_mark/s/sysctl.*/true/' /usr/bin/awg-quick 2>/dev/null || true

# Подменяем resolvconf на stub — пишет напрямую в /etc/resolv.conf
# (awg-quick вызывает: resolvconf -a <iface> -m 0 -x < dns_data)
RUN REAL_RESOLVCONF=$(which resolvconf 2>/dev/null || echo /usr/sbin/resolvconf) && \
    mv "$REAL_RESOLVCONF" "${REAL_RESOLVCONF}.real" 2>/dev/null || true && \
    printf '#!/bin/sh\ncase "$1" in\n  -a) cat > /etc/resolv.conf ;;\n  -u) ;;\n  -d) ;;\n  *) echo "resolvconf stub: unknown args $*" >&2 ;;\nesac\n' > /usr/local/bin/resolvconf && \
    chmod +x /usr/local/bin/resolvconf && \
    ln -sf /usr/local/bin/resolvconf /usr/sbin/resolvconf 2>/dev/null || true

# Копируем скрипт запуска
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Директория для конфига VPN
VOLUME ["/etc/amneziawg"]

ENTRYPOINT ["/entrypoint.sh"]
