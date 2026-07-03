#!/usr/bin/env bash
# nft_backend.sh — реализация через nftables.
# Вся логика живёт в отдельной таблице ip $FW_TABLE_NAME — ничего больше не трогаем.

nft_table_exists() {
    nft list table ip "$FW_TABLE_NAME" >/dev/null 2>&1
}

nft_apply() {
    local ips
    ips="$(cached_ips)"

    if [[ -z "$ips" ]]; then
        echo "[!] Список IP пуст — нечего применять. Проверьте sites.list." >&2
        return 1
    fi

    # Убираем прошлую версию таблицы, если была, чтобы apply был идемпотентным
    nft_table_exists && nft delete table ip "$FW_TABLE_NAME"

    {
        echo "table ip $FW_TABLE_NAME {"
        echo "    set dest_ips {"
        echo "        type ipv4_addr; flags interval;"
        echo "        elements = { $(echo "$ips" | paste -sd, -) }"
        echo "    }"
        echo ""
        echo "    chain output {"
        echo "        type nat hook output priority -100; policy accept;"
        echo "        meta skuid $TOR_UID return"
        echo "        ip daddr 127.0.0.0/8 return"
        echo "        ip daddr @dest_ips tcp dport != $TOR_TRANS_PORT counter redirect to :$TOR_TRANS_PORT"
        echo "    }"
        echo "}"
    } | nft -f -

    echo "[+] nft-таблица '$FW_TABLE_NAME' применена. Сайтов в наборе: $(echo "$ips" | wc -l)"
}

nft_restore() {
    if nft_table_exists; then
        nft delete table ip "$FW_TABLE_NAME"
        echo "[+] nft-таблица '$FW_TABLE_NAME' удалена. Фаервол возвращён к исходному состоянию."
    else
        echo "[i] Таблица '$FW_TABLE_NAME' не найдена — нечего откатывать."
    fi
}

nft_status() {
    if nft_table_exists; then
        nft list table ip "$FW_TABLE_NAME"
    else
        echo "[i] Таблица '$FW_TABLE_NAME' не активна."
    fi
}
