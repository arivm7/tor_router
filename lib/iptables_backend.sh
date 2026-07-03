#!/usr/bin/env bash
# iptables_backend.sh — реализация через iptables (fallback, если nft недоступен).
# Своя цепочка $FW_TABLE_NAME в таблице nat, подключаемая к OUTPUT одним правилом-переходом.

IPT_CHAIN="${FW_TABLE_NAME^^}"   # напр. TOR_ROUTER

ipt_chain_exists() {
    iptables -t nat -L "$IPT_CHAIN" >/dev/null 2>&1
}

ipt_jump_exists() {
    iptables -t nat -C OUTPUT -j "$IPT_CHAIN" >/dev/null 2>&1
}

iptables_apply() {
    local ips
    ips="$(cached_ips)"

    if [[ -z "$ips" ]]; then
        echo "[!] Список IP пуст — нечего применять. Проверьте sites.list." >&2
        return 1
    fi

    iptables_restore_quiet

    iptables -t nat -N "$IPT_CHAIN"
    iptables -t nat -A "$IPT_CHAIN" -m owner --uid-owner "$TOR_UID" -j RETURN
    iptables -t nat -A "$IPT_CHAIN" -d 127.0.0.0/8 -j RETURN

    while IFS= read -r ip; do
        iptables -t nat -A "$IPT_CHAIN" -d "$ip" -p tcp \
            ! --dport "$TOR_TRANS_PORT" -j REDIRECT --to-ports "$TOR_TRANS_PORT"
    done <<< "$ips"

    iptables -t nat -A OUTPUT -j "$IPT_CHAIN"

    echo "[+] iptables-цепочка '$IPT_CHAIN' применена. Сайтов в наборе: $(echo "$ips" | wc -l)"
}

# Тихий откат перед повторным apply (без сообщений)
iptables_restore_quiet() {
    ipt_jump_exists && iptables -t nat -D OUTPUT -j "$IPT_CHAIN"
    if ipt_chain_exists; then
        iptables -t nat -F "$IPT_CHAIN"
        iptables -t nat -X "$IPT_CHAIN"
    fi
}

iptables_restore() {
    if ipt_chain_exists; then
        iptables_restore_quiet
        echo "[+] iptables-цепочка '$IPT_CHAIN' удалена. Фаервол возвращён к исходному состоянию."
    else
        echo "[i] Цепочка '$IPT_CHAIN' не найдена — нечего откатывать."
    fi
}

iptables_status() {
    if ipt_chain_exists; then
        iptables -t nat -L "$IPT_CHAIN" -n -v --line-numbers
    else
        echo "[i] Цепочка '$IPT_CHAIN' не активна."
    fi
}
