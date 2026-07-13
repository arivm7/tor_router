#!/usr/bin/env bash
# =============================================================
# tor-router.sh — управление перенаправлением трафика указанных
# сайтов через сеть Tor посредством firewall (nft/iptables).
# =============================================================
set -euo pipefail

APP_TITLE="Скрипт перенаправления трафика в сеть tor. Эквивалент VPN-TOR"
COPYRIGHT="Copyright (C) 2004-2025 Ariv <ariv@meta.ua> | https://github.com/arivm7 | RI-Network, Kiev, UK"
VERSION="1.2.0 (2026-07-13)"
LAST_CHANGES="\
v1.2.0 (2026-07-13): Добавление --install Создание .desktop-ярлыка для команды apply;
                     установка bash-автодополнения в ~/.bashrc (идемпотентно);
v1.1.0 (2026-07-04): Точечный sudo вместо запуска всего скрипта от root; проверка зависимостей на старте; фикс unbound vars
v1.0.0 (2026-07-02): Базовый функционал
"



APP_NAME=$(basename "${BASH_SOURCE[0]}")                    # Полное имя скрипта, включая расширение
APP_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)      # Путь размещения исполняемого скрипта
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

COLOR_USAGE="\033[1;32m"        # Терминальный цвет для вывода переменной статуса
COLOR_ERROR="\033[0;31m"        # Терминальный цвет для вывода ошибок
COLOR_INFO="\033[0;34m"         # Терминальный цвет для вывода информации (об ошибке или причине выхода)
COLOR_FILENAME="\033[1;36m"     # Терминальный цвет для вывода имён файлов
COLOR_OK="\033[0;32m"           # Терминальный цвет для вывода Ok-сообщения (зелёный)
COLOR_OFF="\033[0m"             # Терминальный цвет для сброса цвета

APP_AWK="awk"

# -------------------------
# Префиксы для вывода сообщений
# -------------------------
PREFIX_OK="${COLOR_OK}[ok]${COLOR_OFF}"
PREFIX_ERROR="${COLOR_ERROR}[er]${COLOR_OFF}"
PREFIX_INFO="${COLOR_INFO}[ii]${COLOR_OFF}"

#
# Рекомендуемый путь по умолчанию для установки скрипта
#
INSTALL_PATH="$HOME/bin"                        

##
##  [CONFIG END] Конец секции конфига
##  ----------------------------------------------------------------------------
##




#
# Вывод сообщения об успехе с префиксом [ok]
# $* -- текст сообщения
#
msg_ok()
{
    echo -e "${PREFIX_OK} $*"
}

#
# Вывод сообщения об ошибке с префиксом [!!] (без выхода из скрипта)
# $* -- текст сообщения
#
msg_error()
{
    echo -e "${PREFIX_ERROR} $*"
}

#
# Вывод информационного сообщения с префиксом [ii]
# $* -- текст сообщения
#
msg_info()
{
    echo -e "${PREFIX_INFO} $*"
}


#
# Вывод строки и выход из скрипта
# $1 -- сообщение
# $2 -- код ошибки. По умолчанию "1"
#
exit_with_msg() {
    local msg="${1:?Строка не передана или пуста. Смотреть вызывающую функцию.}"
    local num="${2:-1}"
    case "${num}" in
    1)
        # log_error "ERR: ${msg}"
        msg="${PREFIX_ERROR} ${msg}"
        ;;
    2)
        # log_error "ERR: ${msg}"
        msg="${PREFIX_ERROR} ${msg}"
        msg="${msg}\nПодсказка по использованию: ${COLOR_USAGE}${APP_NAME} --usage|-u${COLOR_OFF}"
        ;;
    0)
        # log_info "OK: ${msg}"
        msg="${PREFIX_OK} ${msg}"
        ;;
    *)
        # log_info "${msg}"
        msg="${PREFIX_INFO} ${msg}"
        ;;
    esac
    echo -e "${msg}"
    exit "$num"
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
# Установка скрипта в указанное место 
# с проверкой существования файла и возможностью перезаписи
# А также с проверкой наличия конфига 
# Использование: APP --install "~/bin"
# $1      -- путь назначения (необязателен: если пуст, запрашивается
#            подтверждение на использование INSTALL_PATH по умолчанию)
# Возврат -- 0 при успешной установке или при явном отказе от перезаписи;
#            завершает скрипт через exit_with_msg при фатальных ошибках
#            (нет каталога назначения, ошибка копирования и т.п.)
#
#
# Создаёт .desktop-ярлык для команды "apply" (Freedesktop Desktop Entry),
# без внешних зависимостей — всё генерируется прямо в скрипте.
# $1 -- путь к установленному исполняемому файлу
#
create_desktop_entry() {
    local dest="$1"
    local icon_src="${APP_PATH}/icons/tor_router_apply.svg"
    local icon_name="security-high"   # системная иконка-заглушка, если своей нет

    if [[ -f "$icon_src" ]]; then
        local icon_dest_dir="${HOME}/.local/share/icons/hicolor/scalable/apps"
        local icon_dest="${icon_dest_dir}/tor-router-apply.svg"
        mkdir -p "$icon_dest_dir" 2>/dev/null
        if cp "$icon_src" "$icon_dest" 2>/dev/null; then
            icon_name="tor-router-apply"
        else
            msg_info "Не удалось скопировать иконку — использую системную по умолчанию."
        fi
    else
        msg_info "Файл иконки не найден (${icon_src}) — использую системную иконку по умолчанию."
    fi

    local apps_dir="${HOME}/.local/share/applications"
    local desktop_file="${apps_dir}/${FILE_NAME}-apply.desktop"
    mkdir -p "$apps_dir" || { msg_error "Не удалось создать ${apps_dir} — ярлык не создан."; return 1; }

    cat > "$desktop_file" <<DESKTOP
[Desktop Entry]
Type=Application
Version=1.0
Name=Tor Router — Apply
Comment=Tor Router -- применение правил (перенаправление сайтов из sites.list через Tor)
Exec=${dest} apply
Icon=${icon_name}
Terminal=true
Categories=Network;Security;Utility;
DESKTOP
    chmod +x "$desktop_file"

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$apps_dir" >/dev/null 2>&1 || true
    fi

    msg_ok "Ярлык создан: ${desktop_file}"
}

#
# Копирует файл автодополнения рядом с исходным скриптом (если есть) в
# ~/.local/share/tor-router/ и один раз (идемпотентно) подключает его в
# ~/.bashrc. Повторный запуск не создаёт дублирующихся строк.
#
install_bash_completion() {
    local comp_src="${APP_PATH}/completion/tor-router-completion.bash"
    if [[ ! -f "$comp_src" ]]; then
        msg_info "Файл автодополнения не найден рядом со скриптом (${comp_src}) — пропускаю."
        return 0
    fi

    local comp_dest_dir="${HOME}/.local/share/tor-router"
    local comp_dest="${comp_dest_dir}/tor-router-completion.bash"
    mkdir -p "$comp_dest_dir"
    cp "$comp_src" "$comp_dest"

    local bashrc="${HOME}/.bashrc"
    local marker="# tor-router bash completion (auto-added by --install)"

    if [[ -f "$bashrc" ]] && grep -qF "$comp_dest" "$bashrc" 2>/dev/null; then
        msg_info "Автодополнение уже подключено в ${bashrc} — пропускаю."
        return 0
    fi

    {
        echo ""
        echo "$marker"
        echo "[[ -f \"${comp_dest}\" ]] && source \"${comp_dest}\""
    } >> "$bashrc"
    msg_ok "Автодополнение добавлено в ${bashrc}. Выполните: source ${bashrc} (или откройте новый терминал)."
}

#
# Установка скрипта в указанное место
# с проверкой существования файла и возможностью перезаписи,
# генерацией .desktop-ярлыка и подключением bash-автодополнения.
# Использование: APP --install "~/bin"
# $1      -- путь назначения (необязателен: если пуст, запрашивается
#            подтверждение на использование INSTALL_PATH по умолчанию)
# Возврат -- 0 при успешной установке или при явном отказе от перезаписи;
#            завершает скрипт через exit_with_msg при фатальных ошибках
#            (нет каталога назначения и отказ его создать, ошибка копирования и т.п.)
#
cmd_install() {
    local dest_dir="$1"

    if [[ -z "$dest_dir" ]]; then
        if [[ -z "$INSTALL_PATH" ]]; then
            msg_error "Переменная INSTALL_PATH не задана"
            return 1
        fi

        msg_info "Путь назначения не указан."
        read -rp "Использовать путь по умолчанию (${INSTALL_PATH})? [y/N]: " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            dest_dir="$INSTALL_PATH"
        else
            exit_with_msg "Установка отменена." 1
        fi
    fi

    if [[ "$dest_dir" == "~"* ]]; then
        dest_dir="${dest_dir/#\~/$HOME}"
    fi

    # Определяем путь к текущему скрипту
    local src
    src="$(realpath "${BASH_SOURCE[0]}")" || {
        exit_with_msg "Не удалось определить путь к исходному файлу" 1
    }

    # Проверка наличия каталога назначения — если нет, предлагаем создать
    # (а не сразу фатально падаем: ~/bin на свежей системе обычно не существует)
    if [[ ! -d "$dest_dir" ]]; then
        msg_info "Каталог назначения не существует: ${dest_dir}"
        read -rp "Создать его? [y/N]: " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            mkdir -p "$dest_dir" || exit_with_msg "Не удалось создать каталог: ${dest_dir}" 1
        else
            exit_with_msg "Установка отменена." 1
        fi
    fi

    # --- Проверка существования основного файла ---
    local dest="$dest_dir/$APP_NAME"
    if [[ -e "$dest" ]]; then
        read -rp "Файл $dest уже существует. Перезаписать? [y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]] || {
            msg_info "Установка отменена."
            return 0
        }
    fi

    # Копирование
    if cp "$src" "$dest"; then
        chmod +x "$dest" || { msg_error "Ошибка изменения chmod файла"; return 1; }
        msg_ok "Установлено: $dest"
    else
        exit_with_msg "Ошибка копирования" 1
    fi

    # --- Работа с конфигом (не прерывает установку в любом случае) ---
    if [[ -e "$CONFIG_FILE" ]]; then
        msg_info "Обнаружен конфиг-файл: ${COLOR_FILENAME}${CONFIG_FILE}${COLOR_OFF}."
        msg_info "Его можно оставить, перезаписать командой ${COLOR_USAGE}${APP_NAME} -wc|--write-conf${COLOR_OFF}, либо удалить сейчас."
        read -rp "Удалить текущий конфиг $CONFIG_FILE? [y/N]: " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            mv -f "$CONFIG_FILE" "${CONFIG_FILE}.old.$(date +%s)"
            msg_info "Старый конфиг перемещён в ${CONFIG_FILE}.old.<timestamp>"
        else
            msg_info "Оставлен текущий конфиг ${COLOR_FILENAME}${CONFIG_FILE}${COLOR_OFF}"
        fi
    fi

    # --- Ярлык и автодополнение создаются ВСЕГДА, независимо от выбора выше ---
    create_desktop_entry "$dest"
    install_bash_completion

    msg_ok "Установка завершена."
}



#
#  ----------------------------------------------------------------------------
#  Раздел проверки зависимостей: какие программы/пакеты обязательны для работы.
#  ----------------------------------------------------------------------------
#

# Обязательные бинарники (кроме nft/iptables — для них своя OR-проверка ниже)
# и соответствующие им пакеты (для подсказки, чем поставить).
REQUIRED_BINS=(sudo tor getent grep sed awk id ps realpath)
declare -A BIN_TO_PKG=(
    [sudo]="sudo"
    [tor]="tor"
    [getent]="libc-bin"
    [grep]="grep"
    [sed]="sed"
    [awk]="gawk"
    [id]="coreutils"
    [ps]="procps"
    [realpath]="coreutils"
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
    echo "    ${COLOR_USAGE}sudo apt update && sudo apt install -y <пакет1> <пакет2>${COLOR_OFF} ..." >&2
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
        exit_with_msg "${COLOR_ERROR}[!]${COLOR_OFF} Не удалось получить права root через sudo." 1
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
    if grep -qF "${marker}" "${torrc}" 2>/dev/null; then
        echo "[i] torrc уже содержит блок tor-router — пропускаю."
    else
        ensure_priv
        run_priv cp "${torrc}" "${torrc}.bak.$(date +%s)"
        {
            echo ""
            echo "${marker}"
            echo "TransPort 127.0.0.1:${TOR_TRANS_PORT}"
            echo "DNSPort 127.0.0.1:${TOR_DNS_PORT}"
            echo "AutomapHostsOnResolve 1"
            echo "VirtualAddrNetworkIPv4 10.192.0.0/10"
            echo "${marker}"
        } | run_priv tee -a "${torrc}" >/dev/null
        echo "[+] torrc обновлён (бэкап сохранён рядом). TransPort=${TOR_TRANS_PORT} DNSPort=${TOR_DNS_PORT}"
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
echo -e "$(cat << EOF    
${APP_TITLE}
Использование: ${COLOR_USAGE}$APP_NAME <команда> [аргумент]${COLOR_OFF}

  ${COLOR_USAGE}setup${COLOR_OFF}               Настроить Tor (TransPort/DNSPort в torrc) и определить фаервол
  ${COLOR_USAGE}apply${COLOR_OFF}               Применить маршруты для всех сайтов из sites.list
  ${COLOR_USAGE}restore${COLOR_OFF}             Полностью откатить фаервол к исходному состоянию
  ${COLOR_USAGE}status${COLOR_OFF}              Показать текущие правила/цепочки
  ${COLOR_USAGE}list${COLOR_OFF}                Показать содержимое sites.list
  ${COLOR_USAGE}add <domain|ip>${COLOR_OFF}     Добавить запись в sites.list
  ${COLOR_USAGE}remove <domain|ip>${COLOR_OFF}  Удалить запись из sites.list
  ${COLOR_USAGE}refresh${COLOR_OFF}             Перерезолвить домены и переприменить правила (= apply)

  ${COLOR_USAGE}-u|--usage${COLOR_OFF}             Показать справку по использованию
  ${COLOR_USAGE}-h|--help|help${COLOR_OFF}
  ${COLOR_USAGE}-V|--version${COLOR_OFF}        Справка по использованию
  ${COLOR_USAGE}-wc|--write-conf${COLOR_OFF}    Перезапись конфига по умолчанию

  ${COLOR_USAGE}--install [<path>]${COLOR_OFF}  Установить скрипт в указанное место (например, ${COLOR_FILENAME}${APP_NAME} --install ~/bin${COLOR_OFF})
                      Путь установки по умолчанию ${COLOR_FILENAME}${INSTALL_PATH}${COLOR_OFF}.

Права root не требуются для запуска скрипта целиком — при необходимости
он сам запросит sudo только для команд, реально работающих с фаерволом/Tor
(setup, apply, refresh, restore, status).

Версия: ${VERSION}
Последние изменения:
${LAST_CHANGES}
${COPYRIGHT}
EOF
)"
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
        setup)   
            detect_firewall_backend; 
            tor_setup 
            ;;

        apply)   
            cmd_apply 
            ;;

        refresh) 
            cmd_apply 
            ;;

        restore) 
            cmd_restore 
            ;;

        status)  
            cmd_status 
            ;;

        list)    
            cmd_list 
            ;;

        add)     
            cmd_add "${1:-}" 
            ;;

        remove)  
            cmd_remove "${1:-}" 
            ;;

        -u|--usage|-h|--help|help|-V|--version|"") 
            usage 
            ;;

        -wc|--write-conf)
            echo "перезапись конфига по умолчанию: ${CONFIG_FILE}"
            save_config_file
            exit 0
            ;;

        --install)
            cmd_install "${1:-}"
            exit 0
            ;;

        *) echo "Неизвестная команда: $cmd" >&2; usage; exit 1 ;;
    esac
}

read_config_file
check_dependencies
main "$@"
