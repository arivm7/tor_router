#!/usr/bin/env bash
# resolve.sh — парсинг sites.list и превращение доменов/IP в плоский список IP/CIDR.

IPV4_RE='^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$'

# Заменяет "красивые" типографские дефисы/тире (часто прилетают при копипасте
# из документов/чатов с автозаменой "-" -> "‑"/"–"/"—") на обычный ASCII-дефис.
# Без этого домены вида "linux‑gaming.ru" (с U+2011) не резолвятся, т.к. это
# byte-for-byte другая строка, отличная от реального "linux-gaming.ru".
normalize_dashes() {
    sed -e 's/‐/-/g; s/‑/-/g; s/‒/-/g; s/–/-/g; s/—/-/g; s/―/-/g; s/−/-/g'
}

# Читает $SITES_FILE, отбрасывает комментарии/пустые строки.
# Результат построчно выводится в stdout.
read_sites_raw() {
    [[ -f "$SITES_FILE" ]] || { touch "$SITES_FILE"; }
    grep -vE '^\s*(#|$)' "$SITES_FILE" | sed 's/#.*$//' | normalize_dashes | tr -d ' \t\r'
}

# Резолвит один домен в список IPv4 через getent (использует системный резолвер;
# если в torrc включён DNSPort и системный резолвер указывает на него — резолвинг тоже пойдёт через Tor).
resolve_domain() {
    local domain="$1"
    getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u
}

# Строит state/active_ips.cache: "<исходная_запись> <разрешённый_ip_или_cidr>"
build_resolved_cache() {
    mkdir -p "$STATE_DIR"
    local cache="$STATE_DIR/active_ips.cache"
    : > "$cache"

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        if LC_ALL=C grep -qP '[^\x00-\x7F]' <<< "$entry" 2>/dev/null; then
            echo "[!] Внимание: в записи остались не-ASCII символы: '$entry' — вероятно, опечатка/скрытый символ, домен не зарезолвится." >&2
        fi
        if [[ "$entry" =~ $IPV4_RE ]]; then
            echo "$entry $entry" >> "$cache"
        else
            local ips
            ips="$(resolve_domain "$entry")"
            if [[ -z "$ips" ]]; then
                echo "[!] Не удалось разрешить домен: $entry (пропущен)" >&2
                continue
            fi
            while IFS= read -r ip; do
                echo "$entry $ip" >> "$cache"
            done <<< "$ips"
        fi
    done < <(read_sites_raw)

    echo "$cache"
}

# Возвращает только уникальные IP/CIDR из кеша (второй столбец)
cached_ips() {
    local cache="$STATE_DIR/active_ips.cache"
    [[ -f "$cache" ]] && awk '{print $2}' "$cache" | sort -u
}
