# SOCKS5 VPN Adapter

Контейнер Docker, который объединяет AmneziaWG VPN с SOCKS5 прокси. Позволяет легко использовать зашифрованное VPN соединение через стандартный SOCKS5 интерфейс.

## О проекте

Это Docker-образ, который:
- Подключается к AmneziaWG VPN (форк WireGuard с обфускацией для обхода DPI-блокировок)
- Запускает SOCKS5 прокси (3proxy) на порту 1080, который направляет весь трафик через VPN туннель
- Поддерживает опциональную аутентификацию SOCKS5 через переменные окружения
- Обеспечивает автоматическое переподключение и корректное завершение работы

## Возможности

- **VPN туннелирование** — весь трафик через AmneziaWG с обходом DPI
- **SOCKS5 прокси** — простой доступ к VPN через стандартный протокол
- **Аутентификация** — опциональная авторизация пользователей через логин/пароль
- **Автопереподключение** — watchdog автоматически восстанавливает соединение
- **Корректное завершение** — graceful shutdown при остановке контейнера
- **TCP оптимизация** — поддержка BBR, TCP FastOpen и других улучшений
- **Healthcheck** — автоматическая проверка работоспособности прокси
- **Легковесный образ** — на базе Alpine Linux

## Требования

- Docker и Docker Compose
- Модуль BBR должен быть загружен на хост-машине
- Поддержка устройства TUN/TAP
- Файл конфигурации AmneziaWG (.conf)

### Загрузка модуля BBR

#### Linux

```bash
sudo modprobe tcp_bbr
```

Для постоянной загрузки добавьте `tcp_bbr` в файл `/etc/modules-load.d/`:

```bash
echo "tcp_bbr" | sudo tee /etc/modules-load.d/tcp_bbr.conf
```

#### Windows (Docker Desktop + WSL2)

BBR работает в ядре WSL2, но требует ручной активации. В репозитории есть скрипт, который настраивает BBR + fq qdisc в дистрибутиве `docker-desktop`:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-host-bbr.ps1
```

Скрипт необходимо запустить от имени администратора. Он выполняет:
1. Загрузку модуля `tcp_bbr` в ядро WSL
2. Установку `fq` как default qdisc (обязательно для корректной работы BBR)
3. Включение `bbr` как congestion control
4. Сохранение настроек (переживают перезагрузку WSL)

## Быстрый старт

1. Клонируйте репозиторий:

```bash
git clone <репозиторий>
cd socks5-vpn-adapter
```

2. Скопируйте пример конфигурации и заполните реальные значения:

```bash
cp awg0.conf.example awg0.conf
# Отредактируйте awg0.conf с вашими данными (приватный ключ, публичный ключ, endpoint и т.д.)
```

3. (Опционально) Настройте аутентификацию SOCKS5 в `docker-compose.yml`, задав переменные `SOCKS_USER` и `SOCKS_PASS`.

4. Убедитесь, что модуль BBR загружен на хост-машине:

   **Linux:**
   ```bash
   sudo modprobe tcp_bbr
   ```

   **Windows (Docker Desktop + WSL2):**
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\setup-host-bbr.ps1
   ```

5. Запустите контейнер:

```bash
docker compose up -d
```

6. Проверьте работу прокси:

```bash
curl -x socks5h://localhost:1080 https://ifconfig.me
```

В ответ должен прийти IP-адрес VPN-сервера, а не ваш реальный IP.

## Конфигурация

### Переменные окружения

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `SOCKS_PORT` | 1080 | Порт SOCKS5 прокси |
| `SOCKS_USER` | — | Имя пользователя для аутентификации (опционально) |
| `SOCKS_PASS` | — | Пароль для аутентификации (опционально) |

**Примечание**: Аутентификация включается только если заданы обе переменные `SOCKS_USER` и `SOCKS_PASS`.

## Использование

### Через браузер

Настройте SOCKS5 прокси в настройках браузера:
- Хост: localhost
- Порт: 1080
- (При необходимости) Логин и пароль из `SOCKS_USER` и `SOCKS_PASS`

### Через curl

```bash
curl -x socks5h://localhost:1080 https://ifconfig.me
```

С аутентификацией:

```bash
curl -x socks5h://user:pass@localhost:1080 https://ifconfig.me
```

### Через другой контейнер

В `docker-compose.yml` добавьте:

```yaml
service_name:
  network_mode: service:socks5-vpn-adapter
```

Или используйте переменные окружения:

```bash
export ALL_PROXY=socks5h://localhost:1080
docker run --rm curlimages/curl curl https://ifconfig.me
```

## TCP оптимизация

В `docker-compose.yml` настроены следующие параметры ядра для улучшения производительности:

| Параметр | Значение | Описание |
|----------|----------|----------|
| `net.core.default_qdisc` | fq | Очередь по умолчанию для BBR (обязательно для корректной работы) |
| `net.ipv4.tcp_congestion_control` | bbr | Алгоритм управления перегрузкой (BBR) |
| `net.ipv4.tcp_fastopen` | 3 | Включение TCP FastOpen |
| `net.ipv4.tcp_mtu_probing` | 1 | MTU probing при обнаружении black hole |
| `net.ipv4.tcp_keepalive_time` | 60 | Тайм-аут keepalive (в секундах) |
| `net.ipv4.tcp_keepalive_intvl` | 10 | Интервал keepalive (в секундах) |
| `net.ipv4.tcp_keepalive_probes` | 6 | Количество попыток keepalive |
| `net.ipv4.tcp_window_scaling` | 1 | Масштабирование окна TCP |

Эти настройки обеспечивают:
- Высокую пропускную способность с BBR
- Быстрое установление соединения с FastOpen
- Автоматическое определение MTU
- Надежное поддержание соединений

## Безопасность

- **Файл awg0.conf содержит приватные ключи** — никогда не коммитьте его в Git (он уже добавлен в .gitignore)
- Контейнер использует только_capability `NET_ADMIN` (без `SYS_MODULE` для повышения безопасности)
- Healthcheck автоматически проверяет работоспособность прокси
- Изменения в конфигурации требуют перезапуска контейнера

## Устранение неполадок

### VPN не подключается

1. Проверьте файл конфигурации `awg0.conf`:
   - Правильный приватный ключ
   - Правильный публичный ключ сервера
   - Доступный endpoint (адрес и порт)
   - Правильный IP-адрес и сеть

2. Проверьте логи:

```bash
docker logs socks5-amneziawg
```

### BBR не доступен

Если контейнер не может использовать BBR:

```bash
sudo modprobe tcp_bbr
```

Убедитесь, что модуль загружен на хост-машине (sysctls в docker-compose применяются к сетевому пространству контейнера, но BBR должен быть доступен в ядре хоста).

### DNS не работает

Если возникают проблемы с DNS:

1. Проверьте подключение к VPN
2. Попробуйте использовать DNS Cloudflare (1.1.1.1) или Google DNS (8.8.8.8)
3. Проверьте настройки DNS в `awg0.conf`

### Контейнер нездоров

Если healthcheck показывает unhealthy:

1. Проверьте логи:

```bash
docker logs socks5-amneziawg
```

2. Проверьте, что VPN подключен:

```bash
docker exec socks5-amneziawg awg show
```

3. Проверьте, что прокси отвечает:

```bash
curl -x socks5h://localhost:1080 https://ifconfig.me
```

4. Убедитесь, что порт не занят другим приложением

## Лицензия

MIT