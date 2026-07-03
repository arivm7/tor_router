#!/usr/bin/env bash
# =============================================================
# tor-router.sh — управление перенаправлением трафика указанных
# сайтов через сеть Tor посредством firewall (nft/iptables).
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/config/tor-router.conf"

# shellcheck source=/dev/null
source "$CONF_FILE"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/detect.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/resolve.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/tor_setup.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/nft_backend.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/iptables_backend.sh"

usage() {
    cat <<EOF
Использование: $(basename "$0") <команда> [аргумент]

  setup               Настроить Tor (TransPort/DNSPort в torrc) и определить фаервол
  apply               Применить маршруты для всех сайтов из sites.list
  restore             Полностью откатить фаервол к исходному состоянию
  status              Показать текущие правила/цепочки (требует root)
  list                Показать содержимое sites.list
  add <domain|ip>     Добавить запись в sites.list
  remove <domain|ip>  Удалить запись из sites.list
  refresh             Перерезолвить домены и переприменить правила (= apply)

Все firewall-команды требуют root (sudo).
EOF
}

cmd_status() {
    require_root
    detect_firewall_backend
    case "$FW_BACKEND" in
        nft) nft_status ;;
        iptables) iptables_status ;;
    esac
}

cmd_apply() {
    require_root
    detect_firewall_backend
    resolve_tor_uid
    build_resolved_cache >/dev/null
    case "$FW_BACKEND" in
        nft) nft_apply ;;
        iptables) iptables_apply ;;
    esac
}

cmd_restore() {
    require_root
    detect_firewall_backend
    case "$FW_BACKEND" in
        nft) nft_restore ;;
        iptables) iptables_restore ;;
    esac
}

cmd_list() {
    if [[ ! -s "$SITES_FILE" ]]; then
        echo "[i] sites.list пуст."
        return
    fi
    grep -vE '^\s*(#|$)' "$SITES_FILE" || echo "[i] sites.list пуст."
}

cmd_add() {
    local entry="${1:-}"
    [[ -z "$entry" ]] && { echo "Укажите домен или IP: add <domain|ip>" >&2; exit 1; }
    if grep -qxF "$entry" "$SITES_FILE" 2>/dev/null; then
        echo "[i] '$entry' уже есть в списке."
    else
        echo "$entry" >> "$SITES_FILE"
        echo "[+] Добавлено: $entry"
        echo "    Выполните '$(basename "$0") apply', чтобы применить маршрут."
    fi
}

cmd_remove() {
    local entry="${1:-}"
    [[ -z "$entry" ]] && { echo "Укажите домен или IP: remove <domain|ip>" >&2; exit 1; }
    if [[ -f "$SITES_FILE" ]] && grep -qxF "$entry" "$SITES_FILE"; then
        sed -i "\|^${entry//\//\\/}\$|d" "$SITES_FILE"
        echo "[+] Удалено из списка: $entry"
        echo "    Выполните '$(basename "$0") apply', чтобы обновить правила фаервола."
    else
        echo "[i] '$entry' не найдено в sites.list."
    fi
}

main() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        setup)   require_root; detect_firewall_backend; tor_setup ;;
        apply)   cmd_apply ;;
        refresh) cmd_apply ;;
        restore) cmd_restore ;;
        status)  cmd_status ;;
        list)    cmd_list ;;
        add)     cmd_add "${1:-}" ;;
        remove)  cmd_remove "${1:-}" ;;
        -h|--help|help|"") usage ;;
        *) echo "Неизвестная команда: $cmd" >&2; usage; exit 1 ;;
    esac
}

main "$@"
