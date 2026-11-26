# Переход Mono VPN с sing-box на Xray-core: исследование и план

Состояние на 26.11.2026. Выводы основаны на исходном коде Xray-core и libXray (клон репозиториев,
тег `v26.11.9`), а не на пересказах. На этом этапе ничего не заменено: рабочее ядро — sing-box 1.14.4.

## Итог

- **Рекомендуемая интеграция:** libXray `v26.11.9`, собранный через cgo (`python3 build/main.py apple go`)
  в статический `LibXray.xcframework`, линкуется **только** в target `PacketTunnel` вместо `Libbox.xcframework`.
  Пакеты получает встроенный в Xray TUN inbound (`protocol: "tun"`) через дескриптор
  NetworkExtension (`env["xray.tun.fd"]`). **Отдельный tun2socks не нужен.**
- Для существующих VLESS-подписок Xray — эталонная реализация: XHTTP, VLESS `encryption`
  (ML-KEM), gRPC `authority`, TCP `headerType=http`, mKCP, все режимы REALITY/Vision работают
  без отображения в чужую модель конфигурации.
- **Регрессии относительно sing-box** (нужно решить до переключения): в Xray нет транспорта HTTP/2
  (`type=http`/`h2` удалён), нет SIP003-плагинов Shadowsocks (`obfs-local`, `v2ray-plugin`) и шифра
  `aes-192-gcm`. QUIC-транспорт не поддерживают оба ядра.
- **Лицензии:** Xray-core — MPL-2.0 (файловый copyleft), libXray — MIT, зависимости — MIT/BSD/Apache-2.0/MPL-2.0
  и одна LGPL-3.0 со static-linking exception. GPL в сборке нет. Это снимает главный блокер распространения
  текущей версии (sing-box — GPL-3.0-or-later, см. README → «Лицензионные требования»).
- **Главный технический риск — память Network Extension** (лимит iOS ~50 МБ). libXray для iOS сам
  ставит `GOGC=10`, мягкий лимит 30 МБ и периодический `FreeOSMemory`; Xray больше не использует gVisor
  (собственный лёгкий TCP/IP-стек). Реальное потребление нужно измерить на iPhone — это первый шаг плана.

## 1. Версии

| Компонент | Версия | Источник |
|---|---|---|
| Xray-core | **v26.11.9** (тег 09.11.2026; последний стабильный релиз на дату исследования) | `git tag` в XTLS/Xray-core |
| libXray | **v26.11.9** (Go-тег `v1.261109.0`), пинит Xray-core `v1.260327.1-0.20261109052709-676eaf66f8f0` = коммит тега v26.11.9 | `go.mod` libXray |
| Go | `go 1.27` в Xray-core, `go 1.27.3` в libXray | `go.mod` |

libXray совместим только с последним релизом Xray-core и не гарантирует стабильность API
(README libXray, раздел Note) — версии нужно закреплять попарно, как сейчас закреплён sing-box
в `build-libbox.sh`.

## 2. Способы интеграции с iOS

| Вариант | Плюсы | Минусы |
|---|---|---|
| **libXray, cgo** (`build/main.py apple go`) — **рекомендуется** | Поддерживается XTLS, версии синхронны с Xray; C API `CGoInvoke(json)`/`CGoFree`, `module.modulemap` → `import LibXray` из Swift; без ObjC-обёрток gomobile; можно задать минимальную версию iOS | API — JSON-конверт `Invoke` (apiVersion 3), его надо обернуть в Swift; включает весь `main/distro/all` |
| libXray, gomobile (`build/main.py apple gomobile`) | Готовые ObjC/Swift-биндинги | gomobile по умолчанию берёт `latest` (нужно закрепить `LIBXRAY_GOMOBILE_VERSION`); нельзя задать минимальную macOS; лишний слой |
| Собственная Go-обёртка над Xray-core | Полный контроль API | Своя поддержка при каждом релизе Xray; выигрыша в размере нет (см. ниже) |

Проверка размера (linux/arm64, `-s -w`, как приближение): программа с `main/distro/all` — 29,9 МБ,
с урезанным набором (только клиентские VLESS/VMess/Trojan/SS, нужные транспорты, TUN, DNS) — 29,8 МБ:
конфигурационный слой `infra/conf` всё равно тянет почти всё. Урезание импортов смысла не имеет,
поэтому libXray с полным набором — разумный выбор. Для сравнения: бинарник extension с Libbox сейчас ~55 МБ.

**Один Go-рантайм на процесс.** Libbox и LibXray нельзя линковать в один `PacketTunnel` одновременно
(README libXray, WARNING; golang/go#15956). Поэтому переключение ядра — сборочное (одно из двух
фреймворков), а второй target-расширение с новым Bundle ID запрещён ограничениями проекта.

## 3. Работа внутри PacketTunnelProvider

- `proxy/tun/tun_darwin.go`: если задан `xray.tun.fd`, Xray использует дескриптор NetworkExtension
  (дублирует его через `F_DUPFD_CLOEXEC`, ставит non-blocking, закрывает только свою копию — XTLS/Xray-core#6883),
  формат пакетов utun с 4-байтовым заголовком; маршруты и адреса не трогает (`Start()` для чужого fd ничего не делает).
- libXray убрал `SetTunFd`: номер fd передаётся в корневом объекте конфигурации `"env": {"xray.tun.fd": "<n>"}`
  (Xray-core `infra/conf/xray.go`, поле `Env`). Номер fd находится так же, как сейчас в `TunnelPlatformInterface`
  (поиск `utun` через `getsockopt`), пример — в `proxy/tun/README.md`, раздел iOS SUPPORT.
- Адреса, маршруты IPv4/IPv6 и DNS настраиваются в Swift через `NEPacketTunnelNetworkSettings`
  (сейчас их задаёт ядро через `LibboxPlatformInterface`; после перехода — сам провайдер).
- Собственные сокеты процесса Packet Tunnel в туннель не попадают, поэтому `autoSystemRoutingTable`
  и `autoOutboundsInterface` не нужны; при смене сети (Wi-Fi ↔ LTE) соединения переустанавливаются
  через `NWPathMonitor` + перезапуск/`reasserting`.
- Жизненный цикл: `runXray` (из `startTunnel` после `setTunnelNetworkSettings`), `stopXray` (из `stopTunnel`);
  одновременно работает один экземпляр (`ErrAlreadyRunning`).

## 4. Транспорты и параметры подписок

| Возможность из ссылок | sing-box 1.14.4 (сейчас) | Xray-core v26.11.9 |
|---|---|---|
| VLESS + REALITY, Vision (`xtls-rprx-vision`) | ✅ | ✅ (+ `xtls-rprx-vision-udp443`) |
| **XHTTP / SplitHTTP** (`type=xhttp`, `mode`, `extra`) | ❌ | ✅ |
| **VLESS `encryption`** (`mlkem768x25519plus...`) | ❌ | ✅ (`proxy/vless/encryption`) |
| **gRPC `authority` ≠ SNI**, `mode=multi` | ❌ / частично | ✅ (`grpc/dial.go`) |
| **TCP `headerType=http`** | ❌ | ✅ (`transport/internet/headers/http`) |
| **mKCP** | ❌ | ✅ |
| WebSocket (+ early data), HTTPUpgrade | ✅ | ✅ (помечены устаревшими, но работают) |
| HTTP/2 (`type=http`, `h2`) | ✅ | ❌ **удалён** («HTTP transport» → XHTTP) |
| QUIC-транспорт | ❌ | ❌ удалён |
| Shadowsocks AEAD, 2022 | ✅ | ✅ (`aes-192-gcm` — нет) |
| Shadowsocks SIP003-плагины (`obfs-local`, `v2ray-plugin`) | ✅ | ❌ |
| Hysteria2 | не распознаётся парсером | ✅ (`proxy/hysteria`) — можно добавить позже |
| uTLS-отпечатки (`fp`) | ✅ | ✅ (chrome, firefox, safari, ios, edge, 360, qq, random, randomized, ...) |
| ECH, FinalMask, XMUX | ❌ | ✅ |

## 5. DNS, IPv4, IPv6, TCP, UDP

- TUN inbound поддерживает IPv4 и IPv6, TCP, UDP и ICMP Echo (README TUN, SUPPORTED FEATURES).
  Ограничение: остальные ICMP игнорируются, «успешный» TCP-handshake генерируется локально.
- DNS: в `NEPacketTunnelNetworkSettings.dnsSettings` указывается адрес внутри TUN (например, `172.19.0.2`),
  правило маршрутизации `inboundTag: tun, port: 53 → outbound dns`, в `dns.servers` — DoH через прокси
  (`https://1.1.1.1/dns-query`, как сейчас). Имя самого VPN-сервера резолвится системным резолвером
  (`localhost` в `dns` с `domains` сервера) — аналог текущего `default_domain_resolver`.
- Частные сети — `direct` по списку CIDR прямо в конфиге (без `geoip.dat`, чтобы не тащить файлы geo и не тратить память).
- Утечки IPv6: как и сейчас, IPv6-маршрут по умолчанию забирается в туннель, даже если у сервера нет IPv6.

## 6. Память Network Extension

- iOS ограничивает Packet Tunnel ~50 МБ. libXray на iOS (`memory/memory_ios.go`): `debug.SetGCPercent(10)`,
  `debug.SetMemoryLimit(30 МБ)`, `FreeOSMemory` раз в секунду — вызывается из `RunXray`.
- Xray-core заменил gVisor собственным лёгким стеком (XTLS/Xray-core#7130), это заметно снижает
  потребление на пакетном уровне.
- Рисковые места: XHTTP с XMUX (много параллельных потоков), mKCP (буферы), большие очереди UDP.
  Нужны замеры на устройстве (Xcode → Debug Navigator, attach к `PacketTunnel`): простой, видео,
  скачивание, 100+ UDP-сессий; порог — устойчиво < 45 МБ.

## 7. Лицензирование

Проверены лицензии всех Go-модулей, которые реально попадают в сборку libXray для `GOOS=ios`
(`go list -deps`, 96 модулей):

| Лицензия | Модули |
|---|---|
| MPL-2.0 | `xtls/xray-core`, `xtls/reality`, `layeh.com/gopher-luar` |
| MIT | `xtls/libxray`, `apernet/quic-go`, `quic-go/qpack`, `pion/*`, `yuin/gopher-lua`, `wireguard-go`, `robfig/cron`, `klauspost/cpuid`, `ghodss/yaml`, `pelletier/go-toml`, `koron/go-ssdp`, `molecule-man/go-brrr`, `lukechampine.com/blake3` |
| BSD-3 / BSD-2 | `golang.org/x/*`, `google.golang.org/protobuf`, `refraction-networking/utls`, `miekg/dns`, `gorilla/websocket`, `google/uuid`, `klauspost/compress`, `metacubex/{age,hkdf,hpke,mlkem}`, `go4.org/netipx`, `huin/goupnp`, `libp2p/go-netroute`, `wlynxg/anet` |
| Apache-2.0 | `google.golang.org/grpc`, `genproto`, `gopkg.in/yaml.v2`, `libp2p/go-nat`, `jackpal/go-nat-pmp`, `pires/go-proxyproto` |
| LGPL-3.0 + static-linking exception | `juju/ratelimit` (исключение снимает требования 4d/4e о повторной линковке; остальные условия LGPL — уведомление и текст лицензии — остаются) |

Что это значит для Mono VPN:

- MPL-2.0 — файловый copyleft: собственный код приложения может оставаться закрытым; исходники
  **файлов** Xray-core/REALITY/gopher-luar (и их изменения, если будут) должны быть доступны получателям
  (ссылка на точный тег upstream, если файлы не менялись). Дополнительных ограничений, конфликтующих с App Store,
  MPL-2.0 не содержит.
- Нужен экран «Лицензии» в приложении с текстами MPL-2.0, MIT, BSD, Apache-2.0 (включая NOTICE, если есть),
  LGPL-3.0 с исключением.
- Финальное решение о распространении — за владельцем (желательно с юристом), но блокер GPL-3.0 исчезает
  после полного удаления Libbox и кода, написанного по образцу sing-box-for-apple (`TunnelPlatformInterface`).

## 8. App Store

- Требования Apple к VPN-приложениям (организационный аккаунт для VPN, NetworkExtension entitlement,
  политика конфиденциальности, описание сбора данных) не зависят от ядра — см. README.
- Xray-core сам по себе не запрещён: в App Store есть клиенты на его основе. Риски — региональные
  ограничения публикации VPN-приложений, а не ядро.
- `main/distro/all` включает серверные компоненты (inbound VLESS/VMess, commander/gRPC API, Lua в
  `gopher-lua`). Динамической загрузки кода нет (Lua-скрипты не используются в нашей конфигурации),
  но API-сервисы (`api`, `stats`) в конфиг не включать.

## 9. Пошаговый план миграции

Каждый шаг заканчивается проверяемым результатом; sing-box остаётся рабочим ядром до шага 6.

| # | Шаг | Результат / критерий | Риск |
|---|---|---|---|
| 0 | Собрать данные диагностики на iPhone: 3–5 обновлений реальной подписки, отчёты из «Диагностика импорта» | Известны распределение причин (`transport:xhttp`, `encryption:*`, `grpcAuthorityMismatch`, ...) и меняется ли ответ провайдера | — |
| 1 | `Scripts/build-libxray.sh`: закреплённые libXray v26.11.9 / Xray-core v26.11.9 / Go 1.27.3, cgo-сборка `LibXray.xcframework` (ios + iossimulator), проверка коммитов, как в `build-libbox.sh` | Воспроизводимый фреймворк вне git | Низкий |
| 2 | Spike: отдельная ветка, `PacketTunnel` линкует LibXray вместо Libbox (сборочная настройка `MONO_CORE=xray`), минимальный конфиг TUN + VLESS REALITY | Подключение на iPhone, замер памяти: простой / видео / загрузка / UDP | **Высокий** (память) — точка go/no-go |
| 3 | `XrayConfigurationBuilder` (рядом с текущим builder): outbound для VLESS/VMess/Trojan/SS, `streamSettings` для raw/ws/httpupgrade/grpc/xhttp/kcp, TLS/REALITY, DNS/маршрутизация из раздела 5. Модель `ServerConfiguration` расширяется (XHTTP `mode`/`extra`, `authority`, `headerType`, `encryption`) — без значений в логах | Unit-тесты конфигураций + `xray run -test` в CI на Linux | Средний |
| 4 | `ProxyLinkParser`: таблица возможностей ядра (`CoreCapabilities`) вместо зашитых проверок sing-box; для Xray — XHTTP, encryption, authority, headerType, mKCP поддерживаются; HTTP/2 и SS-плагины — «Не поддерживается» | Те же тесты парсинга для обоих ядер; диагностика показывает новые причины | Средний |
| 5 | `PacketTunnelProvider` для Xray: поиск utun fd, `setTunnelNetworkSettings` (IPv4/IPv6/DNS), `runXray`/`stopXray`, обработка смены сети, ошибки в общий Keychain как сейчас. Виджет и таймер не трогаются (они работают через `NEVPNStatus` и конфигурацию в Keychain) | Чек-лист ручного тестирования VPN из README полностью на Xray | Средний |
| 6 | Переключение ядра по умолчанию, экран лицензий, обновление README | Internal TestFlight | Средний |
| 7 | Удаление Libbox, `build-libbox.sh`, `TunnelPlatformInterface` (GPL-наследие) отдельным коммитом | В сборке нет GPL-кода | Низкий |

### Риски и смягчение

| Риск | Вероятность | Смягчение |
|---|---|---|
| Превышение ~50 МБ памяти extension (XHTTP/XMUX, mKCP) | Средняя | Замеры на шаге 2; лимиты XMUX (`maxConcurrency`), отказ от UDP-тяжёлых транспортов в конфиге, `with_low_memory`-аналог — GC-настройки libXray |
| Регрессии: HTTP/2, SS-плагины, `aes-192-gcm` | Низкая для VLESS-подписок | Диагностика шага 0 покажет долю таких серверов; помечать их «Не поддерживается» |
| Нестабильный API libXray | Средняя | Пин версии, тонкая Swift-обёртка над `CGoInvoke`, обновления — только вместе с Xray-core |
| Два Go-рантайма в одном процессе | — | Исключено сборкой: в `PacketTunnel` линкуется только одно ядро |
| DNS-утечки при неверной маршрутизации порта 53 | Средняя | Тест конфигурации + ручная проверка (dnsleaktest) из чек-листа |
| Лицензионные обязательства MPL/LGPL | Низкая | Экран лицензий, ссылки на точные теги исходников |
