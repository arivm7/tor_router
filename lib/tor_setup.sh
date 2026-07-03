#!/usr/bin/env bash
# tor_setup.sh — добавляет TransPort/DNSPort в torrc (один раз) и перезапускает Tor.

find_torrc() {
    for f in /etc/tor/torrc /usr/local/etc/tor/torrc; do
        [[ -f "$f" ]] && { echo "$f"; return 0; }
    done
    return 1
}

tor_setup() {
    check_tor_installed || exit 1

    local torrc
    torrc="$(find_torrc)" || {
        echo "[!] Не найден torrc. Укажите путь вручную и отредактируйте tor_setup.sh." >&2
        exit 1
    }

    local marker="# --- tor-router managed block ---"
    if grep -qF "$marker" "$torrc"; then
        echo "[i] torrc уже содержит блок tor-router — пропускаю."
    else
        cp "$torrc" "${torrc}.bak.$(date +%s)"
        {
            echo ""
            echo "$marker"
            echo "TransPort 127.0.0.1:${TOR_TRANS_PORT}"
            echo "DNSPort 127.0.0.1:${TOR_DNS_PORT}"
            echo "AutomapHostsOnResolve 1"
            echo "VirtualAddrNetworkIPv4 10.192.0.0/10"
            echo "# --- end tor-router managed block ---"
        } >> "$torrc"
        echo "[+] torrc обновлён (бэкап сохранён рядом). TransPort=$TOR_TRANS_PORT DNSPort=$TOR_DNS_PORT"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart tor@default 2>/dev/null || systemctl restart tor 2>/dev/null \
            || echo "[!] Не удалось перезапустить сервис tor через systemctl — перезапустите вручную." >&2
    else
        echo "[i] systemctl не найден — перезапустите демон tor вручную."
    fi

    echo "[+] Setup завершён. Проверьте: ss -ltnp | grep -E '${TOR_TRANS_PORT}|${TOR_DNS_PORT}'"
}
