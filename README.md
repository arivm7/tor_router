# tor-router

Скрипт для перенаправления трафика к выбранным сайтам (по домену или IP/CIDR)
через сеть Tor с помощью firewall-правил (`nftables`, с fallback на `iptables`).

Правила живут в отдельной таблице/цепочке `tor_router` — основной firewall
не трогается. `restore` полностью удаляет эту таблицу/цепочку, возвращая
систему в исходное состояние. Персистентность между перезагрузками не
реализована намеренно (по вашему запросу) — при ребуте все правила и так
исчезают сами.

## Требования

- Linux, `bash`
- установленный `tor` (`apt install tor` / `dnf install tor` / …)
- `nft` (nftables) **или** `iptables` + модуль `xt_owner` (для iptables-варианта)
- `getent` (обычно уже есть, из glibc)
- root-права для команд, меняющих firewall/torrc

## Структура

```
tor-router/
├── tor-router.sh          # главный CLI
├── lib/
│   ├── detect.sh           # root/Tor/firewall detection
│   ├── nft_backend.sh      # реализация на nftables
│   ├── iptables_backend.sh # реализация на iptables (fallback)
│   ├── tor_setup.sh        # настройка torrc
│   └── resolve.sh          # парсинг sites.list + DNS-резолвинг
├── config/
│   ├── tor-router.conf     # настройки (порты, uid tor, имя таблицы)
│   └── sites.list          # список сайтов
├── completion/
│   └── tor-router-completion.bash  # bash-автодополнение (см. ниже)
└── state/
    └── active_ips.cache    # кеш резолвинга (создаётся автоматически)
```

## Автодополнение в bash (Tab)

Добавьте в `~/.bashrc`:
```bash
source /полный/путь/до/tor-router/completion/tor-router-completion.bash
```
Затем `source ~/.bashrc` или откройте новый терминал. После этого:

```bash
./tor-router.sh <Tab><Tab>          # покажет: setup apply refresh restore status list add remove help
./tor-router.sh rem<Tab>            # -> remove
./tor-router.sh remove <Tab><Tab>   # подставит текущие записи из sites.list
sudo ./tor-router.sh remove gi<Tab> # работает и через sudo
```
Для `add` подсказок нет намеренно — значение произвольное (домен/IP/CIDR).

## Быстрый старт

```bash
chmod +x tor-router.sh lib/*.sh

# 1. Один раз: настроить torrc (TransPort/DNSPort) и перезапустить Tor
sudo ./tor-router.sh setup

# 2. Проверить, от какого пользователя реально работает демон tor,
#    и при необходимости поправить TOR_USER в config/tor-router.conf
ps -o user= -C tor

# 3. Добавить сайты
./tor-router.sh add example.com
./tor-router.sh add 203.0.113.0/24

# 4. Посмотреть список
./tor-router.sh list

# 5. Применить маршруты
sudo ./tor-router.sh apply

# 6. Посмотреть активные правила
./tor-router.sh status

# 7. Откатить всё обратно
sudo ./tor-router.sh restore
```

## Команды

| Команда | Требует root | Описание |
|---|---|---|
| `setup` | да | добавляет `TransPort`/`DNSPort` в torrc, перезапускает Tor |
| `apply` / `refresh` | да | резолвит домены из `sites.list`, создаёт правила редиректа в TransPort |
| `restore` | да | удаляет таблицу/цепочку `tor_router` целиком |
| `status` | да | показывает текущие правила |
| `list` | нет | показывает `sites.list` |
| `add <domain\|ip>` | нет | добавляет запись в `sites.list` |
| `remove <domain\|ip>` | нет | убирает запись из `sites.list` |

`add`/`remove` только редактируют конфиг — чтобы правила фаервола
обновились, нужно затем выполнить `apply`.

## Важные ограничения (честно, как есть)

1. **Домены матчатся по IP, а не по SNI/Host.** Скрипт резолвит домен один
   раз при `apply` и редиректит именно эти IP. Если у сайта много IP за
   CDN (Cloudflare и т.п.) или адрес поменялся — вызывайте `refresh`
   заново, иначе часть трафика может пойти в обход Tor.
2. Redirect выполняется в `OUTPUT`-цепочке — то есть перенаправляется
   именно **исходящий с этого ПК** трафик, что и требовалось (не форвардинг
   через ПК как роутер для других устройств).
3. Anti-loop правило исключает трафик самого процесса `tor` (по uid из
   `TOR_USER` в конфиге) — если uid указан неверно, Tor не сможет выйти в
   сеть. Проверяйте `ps -o user= -C tor`.
4. Скрипт не трогает UDP/DNS напрямую — за резолвинг доменов из
   `sites.list` отвечает системный резолвер (`getent`). Если хотите, чтобы
   и сам DNS-запрос для этих доменов уходил через Tor DNSPort, это отдельная
   доработка (маппинг resolv.conf / dnsmasq), не входящая в текущее ТЗ.
5. Тестируйте на непринципиальной машине/VM перед боевым использованием —
   ошибка в правилах output-редиректа теоретически может временно
   заблокировать исходящий трафик до `restore`.
