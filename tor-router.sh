#!/usr/bin/env bash
# =============================================================
# tor-router.sh — управление перенаправлением трафика указанных
# сайтов через сеть Tor посредством firewall (nft/iptables).
# =============================================================
set -euo pipefail

APP_TITLE="Скрипт перенаправления трафика в сеть tor. Эквивалент VPN-TOR"
COPYRIGHT="Copyright (C) 2004-2025 Ariv <ariv@meta.ua> | https://github.com/arivm7 | RI-Network, Kiev, UK"
VERSION="1.1.0 (2026-07-04)"
LAST_CHANGES="\
v1.0.0 (2026-07-02): Базовый функционал
v1.1.0 (2026-07-04): Точечный sudo вместо запуска всего скрипта от root; проверка зависимостей на старте; фикс unbound vars
"



APP_NAME=$(basename "$0")                                   # Полное имя скрипта, включая расширение
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILE_NAME="${APP_NAME%.*}"                                  # Убираем расширение (если есть)

CONFIG_DIRNAME="tor-router"
CONFIG_PATH="${XDG_CONFIG_HOME:-${HOME}/.config}/${CONFIG_DIRNAME}"
CONFIG_FILE="${CONFIG_PATH}/${FILE_NAME}.conf"



##
##  ============================================================================
##  [CONFIG START] Начало секции конфига
##

##
##  Конфиг для скрипта Скрипт перенаправления трафика в сеть tor.
##  VERSION 1.0.0 (2026-07-04)
##

# Порт TransPort в torrc (прозрачный TCP-прокси Tor)
TOR_TRANS_PORT=9040

# Порт DNSPort в torrc (DNS-резолвинг через Tor, опционально)
TOR_DNS_PORT=5353

# Системный пользователь, от имени которого работает демон tor.
# Debian/Ubuntu: debian-tor    Arch/Fedora: toranon/tor    проверьте: ps -o user= -C tor
TOR_USER=debian-tor

# Имя nft-таблицы / iptables-цепочки, которую скрипт создаёт и удаляет.
# Никакие другие таблицы/цепочки не трогаются.
FW_TABLE_NAME=tor_router

# Какой бэкенд использовать: auto | nft | iptables
FIREWALL_BACKEND=auto

# Пути к остальным файлам (обычно менять не нужно)
SITES_FILE="${CONFIG_PATH}/sites.list"
STATE_DIR="${HOME}/.local/state/tor-router"

# Если 1 — ничего не пишется на диск и не выполняется (используется только
# внутренней логикой генерации конфига при первом запуске)
DRY_RUN=0

COLOR_USAGE="\e[1;32m"                          # Терминальный цвет для вывода переменной статуса
COLOR_ERROR="\e[0;31m"                          # Терминальный цвет для вывода ошибок
COLOR_INFO="\e[0;34m"                           # Терминальный цвет для вывода информации (об ошибке или причине выхода)
COLOR_FILENAME="\e[1;36m"                       # Терминальный цвет для вывода имён файлов
COLOR_OFF="\e[0m"                               # Терминальный цвет для сброса цвета

APP_AWK="awk"

##
##  [CONFIG END] Конец секции конфига
##  ----------------------------------------------------------------------------
##



#
#  Печатает сообщение об ошибке цветом COLOR_ERROR и завершает скрипт с кодом $2 (по умолчанию 1).
#
exit_with_msg()
{
    echo -e "${COLOR_ERROR}$1${COLOR_OFF}" >&2
    exit "${2:-1}"
}



#
#  Записывает в конфиг файл фрагмент этого же скрипта между строками, содержащими [CONFIG START] и [CONFIG END]
#  Используемые глобальные переменные: $0 и CONFIG_FILE
#
save_config_file()
{
    mkdir -p "${CONFIG_PATH}"
    echo -e "Инициализация конфиг-файла '${COLOR_FILENAME}${CONFIG_FILE}${COLOR_OFF}'"
    if ! command -v "${APP_AWK}" >/dev/null 2>&1; then
        exit_with_msg "Нет приложения ${COLOR_FILENAME}${APP_AWK}${COLOR_OFF}." 1
    fi
    # Извлечь фрагмент между [CONFIG START] и [CONFIG END] из самого скрипта
    [[ $DRY_RUN -eq 0 ]] && "${APP_AWK}" '/\[\s*CONFIG START\s*\]/,/\[\s*CONFIG END\s*\]/' "$0" > "${CONFIG_FILE}"
}



#
#  Чтение конфигурационного файла.
#  Если его нет, то создание.
#
read_config_file()
{
    if [ -f "${CONFIG_FILE}" ]; then
        # shellcheck disable=SC1090
        source "${CONFIG_FILE}"
    else
        save_config_file
    fi
}



#
#  ----------------------------------------------------------------------------
#  Раздел проверки зависимостей: какие программы/пакеты обязательны для работы.
#  ----------------------------------------------------------------------------
#

# Обязательные бинарники (кроме nft/iptables — для них своя OR-проверка ниже)
# и соответствующие им пакеты (для подсказки, чем поставить).
REQUIRED_BINS=(sudo tor getent grep sed awk id ps)
declare -A BIN_TO_PKG=(
    [sudo]="sudo"
    [tor]="tor"
    [getent]="libc-bin"
    [grep]="grep"
    [sed]="sed"
    [awk]="gawk"
    [id]="coreutils"
    [ps]="procps"
)

check_dependencies()
{
    local missing=()
    local bin

    for bin in "${REQUIRED_BINS[@]}"; do
        command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
    done

    # Нужен хотя бы один firewall-бэкенд: nft ИЛИ iptables
    local have_fw=0
    command -v nft >/dev/null 2>&1 && have_fw=1
    command -v iptables >/dev/null 2>&1 && have_fw=1
    [[ $have_fw -eq 0 ]] && missing+=("nft-or-iptables")

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    echo -e "${COLOR_ERROR}[!] Не найдены необходимые программы:${COLOR_OFF}" >&2
    for bin in "${missing[@]}"; do
        if [[ "$bin" == "nft-or-iptables" ]]; then
            echo -e "    - ${COLOR_FILENAME}nft${COLOR_OFF} или ${COLOR_FILENAME}iptables${COLOR_OFF} (пакет: nftables ИЛИ iptables)" >&2
        else
            echo -e "    - ${COLOR_FILENAME}${bin}${COLOR_OFF} (пакет: ${BIN_TO_PKG[$bin]:-$bin})" >&2
        fi
    done
    echo "" >&2
    echo "Установите недостающее и повторите запуск, например:" >&2
    echo "    sudo apt update && sudo apt install -y <пакет1> <пакет2> ..." >&2
    exit 1
}



#
#  ----------------------------------------------------------------------------
#  Раздел точечного повышения прав: sudo вызывается только там, где реально
#  нужны привилегии, а не для запуска всего скрипта целиком.
#  ----------------------------------------------------------------------------
#

# Запускает переданную команду с правами root: напрямую, если уже root,
# иначе через sudo. Использовать вместо жёсткого require_root на весь скрипт.
run_priv() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Убеждается, что sudo-права доступны (запросит пароль один раз, если нужно,
# дальше sudo кеширует их на ~15 минут). Не запускает сам скрипт от root —
# только "разогревает" sudo перед серией привилегированных вызовов.
ensure_priv() {
    if [[ "$(id -u)" -eq 0 ]]; then
        return 0
    fi
    if ! sudo -v; then
        exit_with_msg "[!] Не удалось получить права root через sudo." 1
    fi
}



#
#  ----------------------------------------------------------------------------
#  Раздел определения окружения: наличие Tor, активный фаервол.
#  ----------------------------------------------------------------------------
#

check_tor_installed() {
    if ! command -v tor >/dev/null 2>&1; then
        echo "[!] Tor не найден в PATH. Установите пакет tor и повторите." >&2
        return 1
    fi
    return 0
}

# Определяет рабочий бэкенд фаервола и экспортирует переменную FW_BACKEND.
# Проверка "nft list ruleset" требует root (без прав может ошибочно
# показать, что nft недоступен) — поэтому идёт через run_priv.
detect_firewall_backend() {
    if [[ "$FIREWALL_BACKEND" != "auto" ]]; then
        FW_BACKEND="$FIREWALL_BACKEND"
        return 0
    fi

    if command -v nft >/dev/null 2>&1 && run_priv nft list ruleset >/dev/null 2>&1; then
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
        echo "[!] Пользователь '$TOR_USER' не найден. Проверьте TOR_USER в конфиге ($CONFIG_FILE)" >&2
        echo "    (подсказка: ps -o user= -C tor)" >&2
        exit 1
    fi
    export TOR_UID
}



#
#  ----------------------------------------------------------------------------
#  Раздел парсинг sites.list и превращение доменов/IP в плоский список IP/CIDR.
#  Не требует прав root — работает с файлами обычного пользователя.
#  ----------------------------------------------------------------------------
#

IPV4_RE='^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$'

# Создаёт $SITES_FILE с шаблоном-подсказкой, если файла ещё нет.
# Существующий файл никогда не трогает и не перезаписывает.
init_sites_file() {
    [[ -f "$SITES_FILE" ]] && return 0

    mkdir -p "$(dirname "$SITES_FILE")"
    cat > "$SITES_FILE" <<'TEMPLATE'
# =============================================================
# sites.list — список сайтов, чей трафик пойдёт через Tor
# По одной записи на строку. Пустые строки и строки с # игнорируются.
# Поддерживаются: домены, одиночные IP, подсети CIDR.
# =============================================================
# Примеры (уберите # и подставьте свои):
# example.com
# 203.0.113.5
# 198.51.100.0/24
TEMPLATE

    echo -e "Создан файл ${COLOR_FILENAME}${SITES_FILE}${COLOR_OFF} с примерами — отредактируйте его вручную или используйте '$(basename "$0") add'."
}

# Заменяет "красивые" типографские дефисы/тире (часто прилетают при копипасте
# из документов/чатов с автозаменой "-" -> "‑"/"–"/"—") на обычный ASCII-дефис.
# Без этого домены вида "linux‑gaming.ru" (с U+2011) не резолвятся, т.к. это
# byte-for-byte другая строка, отличная от реального "linux-gaming.ru".
normalize_dashes() {
    sed -e 's/‐/-/g; s/‑/-/g; s/‒/-/g; s/–/-/g; s/—/-/g; s/―/-/g; s/−/-/g'
}

# Читает $SITES_FILE, отбрасывает комментарии/пустые строки.
read_sites_raw() {
    init_sites_file
    grep -vE '^\s*(#|$)' "$SITES_FILE" | sed 's/#.*$//' | normalize_dashes | tr -d ' \t\r'
}

# Резолвит один домен в список IPv4 через getent.
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
            ips="$(resolve_domain "$entry")" || true
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


#
#  ----------------------------------------------------------------------------
#  TOR SETUP
#  Раздел добавляет TransPort/DNSPort в torrc (один раз) и перезапускает Tor.
#  Запись в /etc/tor/torrc и рестарт сервиса требуют root — идут через run_priv.
#  ----------------------------------------------------------------------------
#

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
        echo "[!] Не найден torrc ни в /etc/tor/torrc, ни в /usr/local/etc/tor/torrc." >&2
        echo "    Отредактируйте функцию find_torrc() в скрипте, указав правильный путь." >&2
        exit 1
    }

    local marker="# --- tor-router managed block ---"
    if grep -qF "$marker" "$torrc" 2>/dev/null; then
        echo "[i] torrc уже содержит блок tor-router — пропускаю."
    else
        ensure_priv
        run_priv cp "$torrc" "${torrc}.bak.$(date +%s)"
        {
            echo ""
            echo "$marker"
            echo "TransPort 127.0.0.1:${TOR_TRANS_PORT}"
            echo "DNSPort 127.0.0.1:${TOR_DNS_PORT}"
            echo "AutomapHostsOnResolve 1"
            echo "VirtualAddrNetworkIPv4 10.192.0.0/10"
            echo "# --- end tor-router managed block ---"
        } | run_priv tee -a "$torrc" >/dev/null
        echo "[+] torrc обновлён (бэкап сохранён рядом). TransPort=$TOR_TRANS_PORT DNSPort=$TOR_DNS_PORT"
    fi

    ensure_priv
    if command -v systemctl >/dev/null 2>&1; then
        run_priv systemctl restart tor@default 2>/dev/null || run_priv systemctl restart tor 2>/dev/null \
            || echo "[!] Не удалось перезапустить сервис tor через systemctl — перезапустите вручную." >&2
    else
        echo "[i] systemctl не найден — перезапустите демон tor вручную."
    fi

    echo "[+] Setup завершён. Проверьте: ss -ltnp | grep -E '${TOR_TRANS_PORT}|${TOR_DNS_PORT}'"
}



#
#  ----------------------------------------------------------------------------
#  Раздел nft backend — реализация через nftables.
#  Вся логика живёт в отдельной таблице ip $FW_TABLE_NAME — ничего больше не трогаем.
#  Все команды nft идут через run_priv (требуют root).
#  ----------------------------------------------------------------------------
#

nft_table_exists() {
    run_priv nft list table ip "$FW_TABLE_NAME" >/dev/null 2>&1
}

nft_apply() {
    local ips
    ips="$(cached_ips)"

    if [[ -z "$ips" ]]; then
        echo "[!] Список IP пуст — нечего применять. Проверьте sites.list." >&2
        return 1
    fi

    # Убираем прошлую версию таблицы, если была, чтобы apply был идемпотентным
    nft_table_exists && run_priv nft delete table ip "$FW_TABLE_NAME"

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
    } | run_priv nft -f -

    echo "[+] nft-таблица '$FW_TABLE_NAME' применена. Сайтов в наборе: $(echo "$ips" | wc -l)"
}

nft_restore() {
    if nft_table_exists; then
        run_priv nft delete table ip "$FW_TABLE_NAME"
        echo "[+] nft-таблица '$FW_TABLE_NAME' удалена. Фаервол возвращён к исходному состоянию."
    else
        echo "[i] Таблица '$FW_TABLE_NAME' не найдена — нечего откатывать."
    fi
}

nft_status() {
    if nft_table_exists; then
        run_priv nft list table ip "$FW_TABLE_NAME"
    else
        echo "[i] Таблица '$FW_TABLE_NAME' не активна."
    fi
}


#
#  ----------------------------------------------------------------------------
#  Раздел iptables backend — реализация через iptables (fallback, если nft недоступен).
#  Своя цепочка $FW_TABLE_NAME в таблице nat, подключаемая к OUTPUT одним правилом-переходом.
#  Все команды iptables идут через run_priv (требуют root).
#  ----------------------------------------------------------------------------
#

IPT_CHAIN="${FW_TABLE_NAME^^}"   # напр. TOR_ROUTER

ipt_chain_exists() {
    run_priv iptables -t nat -L "$IPT_CHAIN" >/dev/null 2>&1
}

ipt_jump_exists() {
    run_priv iptables -t nat -C OUTPUT -j "$IPT_CHAIN" >/dev/null 2>&1
}

iptables_apply() {
    local ips
    ips="$(cached_ips)"

    if [[ -z "$ips" ]]; then
        echo "[!] Список IP пуст — нечего применять. Проверьте sites.list." >&2
        return 1
    fi

    iptables_restore_quiet

    run_priv iptables -t nat -N "$IPT_CHAIN"
    run_priv iptables -t nat -A "$IPT_CHAIN" -m owner --uid-owner "$TOR_UID" -j RETURN
    run_priv iptables -t nat -A "$IPT_CHAIN" -d 127.0.0.0/8 -j RETURN

    while IFS= read -r ip; do
        run_priv iptables -t nat -A "$IPT_CHAIN" -d "$ip" -p tcp \
            ! --dport "$TOR_TRANS_PORT" -j REDIRECT --to-ports "$TOR_TRANS_PORT"
    done <<< "$ips"

    run_priv iptables -t nat -A OUTPUT -j "$IPT_CHAIN"

    echo "[+] iptables-цепочка '$IPT_CHAIN' применена. Сайтов в наборе: $(echo "$ips" | wc -l)"
}

# Тихий откат перед повторным apply (без сообщений)
iptables_restore_quiet() {
    ipt_jump_exists && run_priv iptables -t nat -D OUTPUT -j "$IPT_CHAIN"
    if ipt_chain_exists; then
        run_priv iptables -t nat -F "$IPT_CHAIN"
        run_priv iptables -t nat -X "$IPT_CHAIN"
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
        run_priv iptables -t nat -L "$IPT_CHAIN" -n -v --line-numbers
    else
        echo "[i] Цепочка '$IPT_CHAIN' не активна."
    fi
}



#
#  ----------------------------------------------------------------------------
#  Конец разделов
#  ----------------------------------------------------------------------------
#



usage() {
    cat <<EOF
${APP_TITLE}
Использование: $APP_NAME <команда> [аргумент]

  setup               Настроить Tor (TransPort/DNSPort в torrc) и определить фаервол
  apply               Применить маршруты для всех сайтов из sites.list
  restore             Полностью откатить фаервол к исходному состоянию
  status              Показать текущие правила/цепочки
  list                Показать содержимое sites.list
  add <domain|ip>     Добавить запись в sites.list
  remove <domain|ip>  Удалить запись из sites.list
  refresh             Перерезолвить домены и переприменить правила (= apply)

  -u|--usage
  -h|--help|help
  -V|--version        Справка по использованию

Права root не требуются для запуска скрипта целиком — при необходимости
он сам запросит sudo только для команд, реально работающих с фаерволом/Tor
(setup, apply, refresh, restore, status).

Версия: ${VERSION}
Последние изменения:
${LAST_CHANGES}
${COPYRIGHT}
EOF
}

cmd_status() {
    ensure_priv
    detect_firewall_backend
    case "$FW_BACKEND" in
        nft) nft_status ;;
        iptables) iptables_status ;;
    esac
}

cmd_apply() {
    ensure_priv
    detect_firewall_backend
    resolve_tor_uid
    build_resolved_cache >/dev/null
    case "$FW_BACKEND" in
        nft) nft_apply ;;
        iptables) iptables_apply ;;
    esac
}

cmd_restore() {
    ensure_priv
    detect_firewall_backend
    case "$FW_BACKEND" in
        nft) nft_restore ;;
        iptables) iptables_restore ;;
    esac
}

cmd_list() {
    init_sites_file
    if [[ ! -s "$SITES_FILE" ]]; then
        echo "[i] sites.list пуст."
        return
    fi
    grep -vE '^\s*(#|$)' "$SITES_FILE" || echo "[i] sites.list пуст."
}

cmd_add() {
    local entry="${1:-}"
    [[ -z "$entry" ]] && { echo "Укажите домен или IP: add <domain|ip>" >&2; exit 1; }
    init_sites_file
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
        setup)   detect_firewall_backend; tor_setup ;;
        apply)   cmd_apply ;;
        refresh) cmd_apply ;;
        restore) cmd_restore ;;
        status)  cmd_status ;;
        list)    cmd_list ;;
        add)     cmd_add "${1:-}" ;;
        remove)  cmd_remove "${1:-}" ;;
        -u|--usage|-h|--help|help|-V|--version|"") usage ;;
        *) echo "Неизвестная команда: $cmd" >&2; usage; exit 1 ;;
    esac
}

read_config_file
check_dependencies
main "$@"
