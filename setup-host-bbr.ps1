# setup-host-bbr.ps1 — Настройка BBR + fq в Docker Desktop WSL2
#
# Запуск от имени администратора:
#   powershell -ExecutionPolicy Bypass -File .\setup-host-bbr.ps1
#
# Что делает:
#   1. Находит WSL-дистрибутив Docker Desktop (docker-desktop)
#   2. Загружает модуль tcp_bbr
#   3. Устанавливает fq как default qdisc (требуется для BBR)
#   4. Включает BBR как congestion control
#   5. Делает настройки постоянными (переживают перезагрузку WSL)

$ErrorActionPreference = "Stop"

# Проверяем, что скрипт запущен от имени администратора
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Ошибка: Запустите PowerShell от имени администратора" -ForegroundColor Red
    exit 1
}

# Проверяем, что WSL доступен
if ($null -eq (Get-Command wsl -ErrorAction SilentlyContinue)) {
    Write-Host "Ошибка: WSL не найден" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== Настройка BBR + fq для Docker Desktop (WSL2) ===" -ForegroundColor Cyan
Write-Host ""

# Ищем WSL-дистрибутив Docker Desktop
Write-Host -NoNewline "  Поиск docker-desktop WSL... "
$distrosRaw = wsl -l -q 2>&1
# wsl -l возвращает строки с BOM и trailing \0, чистим
$distros = $distrosRaw | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim("`0"," ",([char]0x0000)) } | Where-Object { $_ -ne '' }

$dockerDistro = $distros | Where-Object { $_ -eq 'docker-desktop' } | Select-Object -First 1

if (-not $dockerDistro) {
    Write-Host "НЕ НАЙДЕН" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Дистрибутив 'docker-desktop' не найден в WSL." -ForegroundColor Red
    Write-Host "  Убедитесь, что Docker Desktop запущен." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Доступные дистрибутивы:" -ForegroundColor DarkGray
    $distros | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkGray }
    exit 1
}

Write-Host $dockerDistro -ForegroundColor Green
Write-Host ""

# Хелпер: выполнить команду в docker-desktop WSL от имени root
function Invoke-DockerWSL {
    param([string]$Command)
    return wsl -d $dockerDistro -u root -- bash -c $Command 2>&1
}

# Выполняем команды
$steps = @(
    @{ Desc = "Загрузка модуля tcp_bbr";  Cmd = "modprobe tcp_bbr 2>&1" },
    @{ Desc = "Установка fq qdisc";       Cmd = "sysctl -w net.core.default_qdisc=fq 2>&1" },
    @{ Desc = "Включение BBR";            Cmd = "sysctl -w net.ipv4.tcp_congestion_control=bbr 2>&1" }
)

$allOk = $true
foreach ($step in $steps) {
    Write-Host -NoNewline "  $($step.Desc)... "
    $result = Invoke-DockerWSL $step.Cmd
    if ($LASTEXITCODE -eq 0 -or $result -match "already loaded|cannot insert") {
        Write-Host "OK" -ForegroundColor Green
    } else {
        Write-Host "WARN" -ForegroundColor Yellow
        Write-Host "    $result" -ForegroundColor DarkGray
        $allOk = $false
    }
}

# Проверяем результат
Write-Host ""
Write-Host -NoNewline "  qdisc:            "
$qdisc = (Invoke-DockerWSL "cat /proc/sys/net/core/default_qdisc 2>/dev/null").Trim()
Write-Host $qdisc -ForegroundColor $(if ($qdisc -eq "fq") { "Green" } else { "Red" })

Write-Host -NoNewline "  congestion ctrl:  "
$cc = (Invoke-DockerWSL "cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null").Trim()
Write-Host $cc -ForegroundColor $(if ($cc -eq "bbr") { "Green" } else { "Red" })

# Персистенция — пишем в /etc/sysctl.d внутри docker-desktop дистрибутива
Write-Host ""
Write-Host "  Сохранение настроек в $dockerDistro (переживут перезагрузку WSL)..."
Invoke-DockerWSL "grep -q 'tcp_bbr' /etc/modules-load.d/bbr.conf 2>/dev/null || echo 'tcp_bbr' >> /etc/modules-load.d/bbr.conf; grep -q 'default_qdisc' /etc/sysctl.d/99-bbr.conf 2>/dev/null || { echo 'net.core.default_qdisc=fq' > /etc/sysctl.d/99-bbr.conf; echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.d/99-bbr.conf; }" | Out-Null

if ($qdisc -eq "fq" -and $cc -eq "bbr") {
    Write-Host ""
    Write-Host "  Готово! BBR + fq активны." -ForegroundColor Green
    Write-Host "  Перезапустите контейнер: docker compose up -d --build" -ForegroundColor DarkGray
} else {
    Write-Host ""
    Write-Host "  BBR/fq не удалось активировать." -ForegroundColor Yellow
    Write-Host "  Убедитесь, что ядро WSL поддерживает BBR (Windows 10 1903+ / Windows 11)." -ForegroundColor DarkGray
}

Write-Host ""
