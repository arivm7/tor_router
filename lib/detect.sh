#!/usr/bin/env bash
# detect.sh — определение окружения: права, наличие Tor, активный фаервол.

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "[!] Нужны права root (запустите через sudo)." >&2
        exit 1
    fi
}

check_tor_installed() {
    if ! command -v tor >/dev/null 2>&1; then
        echo "[!] Tor не найден в PATH. Установите пакет tor и повторите." >&2
        return 1
    fi
    return 0
}

# Определяет рабочий бэкенд фаервола и экспортирует переменную FW_BACKEND.
detect_firewall_backend() {
    if [[ "$FIREWALL_BACKEND" != "auto" ]]; then
        FW_BACKEND="$FIREWALL_BACKEND"
        return 0
    fi

    if command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
        FW_BACKEND="nft"
    elif command -v iptables >/dev/null 2>&1; then
        FW_BACKEND="iptables"
    else
        echo "[!] Не найден ни nft, ни iptables." >&2
        exit 1
    fi
    export FW_BACKEND
}

# uid пользователя, от имени которого работает демон tor (нужно для anti-loop правил)
resolve_tor_uid() {
    if id -u "$TOR_USER" >/dev/null 2>&1; then
        TOR_UID="$(id -u "$TOR_USER")"
    else
        echo "[!] Пользователь '$TOR_USER' не найден. Проверьте TOR_USER в tor-router.conf" >&2
        echo "    (подсказка: ps -o user= -C tor)" >&2
        exit 1
    fi
    export TOR_UID
}
