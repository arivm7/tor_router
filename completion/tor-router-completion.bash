# =============================================================
# tor-router-completion.bash — bash-автодополнение для tor-router.sh
#
# Подключение (в ~/.bashrc):
#   source /путь/к/tor-router/completion/tor-router-completion.bash
#
# Поддерживает:
#   - дополнение подкоманд: setup apply refresh restore status list add remove
#     help -h --help -u --usage -V --version -wc --write-conf --install
#   - дополнение для `remove <TAB>` — подставляет существующие записи из sites.list
#   - дополнение для `--install <TAB>` — подставляет каталоги (директории)
#   - работает как при прямом вызове (./tor-router.sh, tor-router.sh),
#     так и через sudo (sudo ./tor-router.sh ...)
# =============================================================

_tor_router_complete() {
    local cur words cword
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"

    # Пропускаем ведущие "sudo" (и возможные его опции вида sudo -E),
    # чтобы найти реальный индекс имени скрипта в COMP_WORDS.
    local i=0
    while [[ $i -lt ${#COMP_WORDS[@]} && "${COMP_WORDS[$i]}" == "sudo" ]]; do
        ((i++))
        # пропустить возможные опции sudo типа -E, -H и т.п.
        while [[ $i -lt ${#COMP_WORDS[@]} && "${COMP_WORDS[$i]}" == -* ]]; do
            ((i++))
        done
    done

    local script_index=$i
    local script_path="${COMP_WORDS[$script_index]}"
    local sub_index=$((script_index + 1))

    local commands="setup apply refresh restore status list add remove help -h --help -u --usage -V --version -wc --write-conf --install"

    # Первый аргумент после имени скрипта — подкоманда
    if [[ $COMP_CWORD -eq $sub_index ]]; then
        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
        return 0
    fi

    local subcmd="${COMP_WORDS[$sub_index]}"
    local arg_index=$((sub_index + 1))

    if [[ $COMP_CWORD -eq $arg_index ]]; then
        case "$subcmd" in
            remove)
                local sites_file
                sites_file="$(_tor_router_sites_file)"
                if [[ -f "$sites_file" ]]; then
                    local entries
                    entries="$(grep -vE '^[[:space:]]*(#|$)' "$sites_file" 2>/dev/null \
                                | sed 's/#.*$//' | tr -d ' \t\r')"
                    COMPREPLY=( $(compgen -W "$entries" -- "$cur") )
                fi
                ;;
            add)
                # Для add подставлять нечего (произвольный домен/IP) —
                # оставляем стандартное дополнение выключенным.
                COMPREPLY=()
                ;;
            --install)
                # После --install ожидается путь-каталог назначения
                COMPREPLY=( $(compgen -d -- "$cur") )
                ;;
            *)
                COMPREPLY=()
                ;;
        esac
        return 0
    fi

    return 0
}

# sites.list живёт в XDG-конфиге пользователя (~/.config/tor-router/sites.list),
# а не рядом со скриптом — так же, как вычисляет путь сам tor-router.sh.
_tor_router_sites_file() {
    echo "${XDG_CONFIG_HOME:-$HOME/.config}/tor-router/sites.list"
}

# Регистрируем автодополнение для типичных способов вызова скрипта.
complete -F _tor_router_complete tor-router.sh
complete -F _tor_router_complete ./tor-router.sh
