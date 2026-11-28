# Mono VPN

Минималистичный VPN-клиент для iOS. Пользователь вставляет ссылку на подписку своего
VPN-провайдера, выбирает сервер и нажимает кнопку подключения. У приложения нет собственных
серверов, backend, аналитики и авторизации: оно подключается к серверам стороннего провайдера
из подписки пользователя.

- **Версия:** 1.0.0 (build 1), iOS 17.0+, только iPhone, портретная ориентация, интерфейс на русском.
- **VPN-ядро:** [Xray-core](https://github.com/XTLS/Xray-core) **v26.11.9** через
  [libXray](https://github.com/XTLS/libXray) v26.11.9 (статическая библиотека
  `LibXray.xcframework`, собирается локально).
- **Стек:** Swift, SwiftUI, Swift Concurrency, NetworkExtension (`NETunnelProviderManager` +
  `NEPacketTunnelProvider`), WidgetKit и App Intents, Keychain, App Groups.
- **Зависимости:** сторонних Swift-пакетов нет; Go-зависимости libXray перечислены в
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Подготовка к App Store: [лицензии](docs/licensing.md) ·
[конфиденциальность и App Privacy](docs/app-store-privacy.md) ·
[Export Compliance](docs/export-compliance.md).

---

## Содержание

1. [Возможности](#возможности)
2. [Архитектура](#архитектура)
3. [Сборка](#сборка)
4. [Идентификаторы и подпись](#идентификаторы-и-подпись)
5. [Подписки и протоколы](#подписки-и-протоколы)
6. [Безопасность конфигураций провайдера](#безопасность-конфигураций-провайдера)
7. [Маршрутизация и DNS](#маршрутизация-и-dns)
8. [Виджет](#виджет)
9. [Данные и конфиденциальность](#данные-и-конфиденциальность)
10. [Лицензии](#лицензии)
11. [Публикация в App Store](#публикация-в-app-store)
12. [Известные ограничения](#известные-ограничения)
13. [Чек-лист ручного тестирования](#чек-лист-ручного-тестирования)

---

## Возможности

- **Импорт подписки.** HTTPS-ссылка на подписку или одна прокси-ссылка (`vless://`,
  `vmess://`, `trojan://`, `ss://`). Есть обновление вручную и удаление подписки.
- **JSON-подписки панелей** (Remnawave и подобные): готовые конфиги Xray с балансировщиками
  «Авто», Hysteria, собственными DNS и правилами провайдера.
- **Список серверов на главном экране.** Неподдерживаемые серверы показаны неактивными.
  Причины видны в «Подписка → Диагностика импорта».
- **Подключение одной кнопкой.** Статус и время подключения всегда берутся из системы
  (`NEVPNStatus`, `connectedDate`). Под таймером — скорость трафика и предупреждение, если
  сервер не возвращает данные.
- **Смена сервера при включённом VPN:** туннель останавливается с подтверждением системы
  и запускается с новым сервером.
- **Виджет Home Screen** для подключения и отключения последнего выбранного сервера.
- **Экран «Перед подключением»** с описанием обработки данных — показывается перед первым
  подключением, в том числе начатым из виджета.
- **Ссылки «Политика конфиденциальности» и «Лицензии»** в листе «Подписка».

## Архитектура

```
MonoVPN.xcodeproj
Frameworks/                  LibXray.xcframework (собирается скриптом, в git не хранится)
THIRD_PARTY_NOTICES.md       лицензии сторонних компонентов (генерируется)
third_party/sources/         точные исходники Xray-core, REALITY, gopher-luar (MPL-2.0) и libXray
docs/                        лицензии, конфиденциальность, Export Compliance
MonoVPN/
├── App/                     MonoVPNApp — точка входа, команды виджета, очистка данных прежних версий
├── Core/
│   ├── VPN/                 VPNManager, XrayConfigurationBuilder, XrayPanelConfiguration, TrafficMeter
│   ├── Networking/          SubscriptionService (загрузка подписки)
│   ├── Parsing/             SubscriptionParser, ProxyLinkParser, XrayJSONSubscriptionParser
│   └── Storage/             AppStateStore (Keychain), PanelConfigurationStore (файл), LegacyDiagnosticsCleanup
├── Models/                  ServerConfiguration, Subscription, AppState, VPNCore
├── Features/
│   ├── Home/                главный экран, модель, скорость трафика
│   ├── Servers/             список серверов
│   ├── Subscription/        лист «Подписка», диагностика импорта
│   ├── Privacy/             экран «Перед подключением»
│   └── Legal/               ссылка на политику, экран «Лицензии»
├── DesignSystem/            палитра, стили кнопок, общие компоненты
├── Resources/               Assets, Localizable.xcstrings, PrivacyInfo.xcprivacy, ThirdPartyNotices.json
├── Shared/                  общий код app/extension/widget: TunnelController, SecureStorage,
│                            XrayConfigurationPolicy, XrayRuntimeConfiguration, WidgetCommand, Tunnel.xcstrings
├── Intents/                 ToggleVPNIntent (App Intent виджета)
├── PacketTunnel/            XrayPacketTunnelProvider, XrayCore (C API libXray), PrivacyInfo.xcprivacy
├── Widget/                  виджет, строки, PrivacyInfo.xcprivacy
├── Config/                  Identifiers.xcconfig, Info.plist, entitlements
├── Scripts/                 сборка libXray, копия исходников, генерация уведомлений, проверка Privacy Manifest
└── Tests/                   unit-тесты (Swift Testing)
```

Папки подключены к Xcode как синхронизируемые группы (Xcode 16+): файлы в папке автоматически
входят в targets, указанные ниже.

| Target | Тип | Папки |
|---|---|---|
| `MonoVPN` | приложение | App, Core, Models, Features, DesignSystem, Resources, Shared, Intents |
| `PacketTunnel` | Packet Tunnel Provider extension | PacketTunnel, Shared + `LibXray.xcframework`, NetworkExtension, UIKit, libresolv |
| `MonoVPNWidget` | Widget extension | Widget, Shared, Intents |
| `MonoVPNTests` | unit-тесты (host — приложение) | Tests |

### Основные компоненты

- **SubscriptionService** — принимает только HTTPS-ссылку на подписку или одиночную
  прокси-ссылку. Загружает через эфемерную `URLSession` (без cookies и кэша, `User-Agent:
  MonoVPN/<версия>`): сначала `<адрес>/json` (JSON-подписка Xray), затем обычную подписку со
  ссылками. При ошибке ничего не меняет — последняя рабочая подписка сохраняется.
- **ProxyLinkParser / SubscriptionParser** — разбирают ссылки (plain text или Base64).
  Неподдерживаемые записи не теряются молча, а попадают в диагностику импорта.
- **XrayConfigurationBuilder** — конфигурация Xray для сервера из ссылки.
  **XrayPanelConfiguration** — адаптация готового конфига из JSON-подписки.
- **XrayConfigurationPolicy** — ограничения безопасности для любой конфигурации (см. ниже).
- **AppStateStore / SecureStorage** — подписка, серверы, выбранный сервер и конфигурация
  туннеля хранятся в Keychain.
- **VPNManager** (`@MainActor @Observable`) — владеет `NETunnelProviderManager` и отражает
  `NEVPNStatus`. Системные операции идут через общий **TunnelController**, им же пользуется
  виджет.
- **XrayPacketTunnelProvider** (`PacketTunnel/`) — читает конфигурацию из общего Keychain,
  заранее разрешает имена серверов, настраивает `NEPacketTunnelNetworkSettings`, передаёт
  дескриптор utun во встроенный TUN Xray и запускает ядро. Конфигурация берётся из Keychain,
  поэтому туннель может запустить и система, и «Настройки → VPN», и виджет.

## Сборка

### Требования

- macOS с Xcode 16 или новее.
- Go ≥ 1.21 (`brew install go`); нужный тулчейн (`go1.27.3`) Go скачает сам.
- git.

### Шаги

1. Соберите VPN-ядро. Скрипт закрепляет libXray v26.11.9 (commit `5a0f7d8d…`), Xray-core
   v26.11.9 (commit `676eaf66…`) и Go 1.27.3, проверяет `go.sum`, собирает срезы `ios-arm64` и
   симулятора и создаёт `Frameworks/LibXray.xcframework` и `Frameworks/LIBXRAY_VERSION`:

   ```bash
   MonoVPN/Scripts/build-libxray.sh
   ```

   Только для устройства (быстрее):

   ```bash
   PLATFORMS=ios MonoVPN/Scripts/build-libxray.sh
   ```

2. Откройте проект:

   ```bash
   open MonoVPN.xcodeproj
   ```

3. Сборка без подписи:

   ```bash
   xcodebuild -project MonoVPN.xcodeproj -scheme MonoVPN -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
   ```

4. Unit-тесты (нужен срез симулятора в `LibXray.xcframework`):

   ```bash
   xcodebuild test -project MonoVPN.xcodeproj -scheme MonoVPN -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MonoVPNTests CODE_SIGNING_ALLOWED=NO
   ```

Packet Tunnel не работает в симуляторе: VPN проверяется только на устройстве. Для запуска на
iPhone нужна подпись с командой, у которой есть возможность Network Extensions.

## Идентификаторы и подпись

Все идентификаторы и версии заданы в одном месте — `MonoVPN/Config/Identifiers.xcconfig`.
Info.plist всех targets и Swift-код (`AppIdentifiers`) читают значения оттуда.

| Параметр | Значение |
|---|---|
| Display Name | Mono VPN |
| Версия / сборка | `MARKETING_VERSION = 1.0.0`, `CURRENT_PROJECT_VERSION = 1` |
| App Bundle ID | `com.irklch.monovpn` |
| Packet Tunnel Bundle ID | `com.irklch.monovpn.PacketTunnel` |
| Widget Bundle ID | `com.irklch.monovpn.Widget` |
| App Group | `group.com.irklch.monovpn` |
| Keychain Sharing | `$(AppIdentifierPrefix)com.irklch.monovpn.shared` |
| Подпись | Automatic; Team ID задан в настройках targets (`DEVELOPMENT_TEAM`) |

У всех трёх targets одинаковые entitlements (`MonoVPN/Config/*.entitlements`): Network
Extensions → Packet Tunnel, App Groups, Keychain Sharing. Виджету Packet Tunnel нужен, потому
что он читает состояние `NETunnelProviderManager`.

После смены команды разработчика (например, при переходе на Organization) Team ID меняется в
настройках всех трёх targets; App ID, App Group и Keychain group регистрируются заново.

## Подписки и протоколы

### Форматы

| Формат | Поддержка |
|---|---|
| HTTPS, тело — ссылки по одной в строке или Base64 (стандартный / URL-safe) | ✅ |
| HTTPS, `<адрес>/json` — массив готовых конфигов Xray (Remnawave и подобные панели) | ✅ запрашивается первым |
| Одна ссылка `vless://` / `vmess://` / `trojan://` / `ss://` вместо адреса | ✅ |
| HTTP без TLS | ❌ отклоняется: токен подписки мог бы быть перехвачен |
| Clash / Mihomo YAML, sing-box JSON, HTML | ❌ распознаётся и отклоняется с сообщением |

### Ссылки

| Протокол | Транспорты | Безопасность |
|---|---|---|
| VLESS (`encryption=none`) | RAW/TCP, WebSocket (с early data `?ed=`), gRPC, HTTPUpgrade, XHTTP | none, TLS, REALITY; flow `xtls-rprx-vision` (только TCP + TLS/REALITY) |
| VMess (v2rayN JSON) | те же | none, TLS |
| Trojan | те же | TLS (по умолчанию), REALITY |
| Shadowsocks (SIP002 и legacy) | TCP/UDP | `2022-blake3-*`, `aes-128-gcm`, `aes-256-gcm`, `(x)chacha20-ietf-poly1305` |

Параметр `fm` (finalmask Xray) поддерживается.

Сервер виден в списке как «Не поддерживается»:
- HTTP/2-транспорт (в Xray-core удалён);
- mKCP, QUIC-транспорт;
- TCP `headerType` ≠ `none`;
- VLESS `encryption` ≠ `none`;
- flow, отличный от `xtls-rprx-vision`;
- плагины Shadowsocks (`obfs-local`, `v2ray-plugin`), `aes-192-gcm` и потоковые шифры Shadowsocks.

Vision на транспортах, отличных от TCP, не применяется — так же поступают эталонные клиенты
Xray.

«Частично применены» (сервер поддерживается, параметр показан в диагностике):
- `allowInsecure` — проверка сертификата никогда не отключается;
- `spx`;
- неизвестный `fp` — заменяется на `chrome`;
- gRPC `mode=multi`;
- прочие неизвестные параметры.

### JSON-подписка

Конфиг сервера запускается почти как есть (`XrayPanelConfiguration`):

- входы `socks`/`http` заменяются встроенным TUN Xray с теми же настройками sniffing;
- DNS-запросы из TUN всегда уходят в outbound `dns`;
- ссылки на геобазы (`geosite:`, `geoip:`, `ext:`) убираются, потому что файлов геобаз в
  сборке нет; `geoip:private` заменяется списком частных сетей; правило без оставшихся
  условий удаляется;
- применяется `XrayConfigurationPolicy`.

Конфиги хранятся в файле `Application Support/panel-configurations.json` (защита до первой
разблокировки, без резервного копирования). Конфиг выбранного сервера кладётся в общий
Keychain для расширения и виджета. ID сервера зависит от имени, поэтому выбор переживает смену
ключей и адресов.

### Диагностика импорта

«Подписка → Диагностика импорта» показывает:
- неподдерживаемые серверы с причиной;
- нераспознанные записи;
- неприменённые параметры.

Отображаются только имена серверов, протоколов и параметров — без UUID, паролей, значений
параметров и адреса подписки. Журналы, сведения о работе туннеля и история обновлений не
собираются.

## Безопасность конфигураций провайдера

`MonoVPN/Shared/XrayConfigurationPolicy.swift` применяется при импорте и ещё раз в расширении
перед запуском ядра:

- **Lua-скрипты не исполняются.** Конфиг с `routing.script`, `dns.script` или `script` маски
  finalmask отклоняется с понятной причиной.
- **Журналы выключены.** Журнал Xray заменяется на выключенный (`access`, `error`,
  `loglevel` — `none`, `dnsLog: false`). Убираются включённый `masterKeyLog` (запись ключей
  TLS) и `debug: true` в параметрах QUIC.
- **`env`.** Остаются только настройки буферов и протоколов, в тех написаниях, которые читает
  Xray (`xray.buf.readv` / `XRAY_BUF_READV`); `xray.tun.fd` задаёт только расширение.
- **Поля верхнего уровня** приводятся к каноническому написанию. Поле, заданное несколько раз
  в разном написании, — отказ: неизвестно, какое значение применил бы Xray.
- **Написанием ключа ограничения не обойти.** Имена ключей сравниваются так же, как в Go:
  без учёта регистра ASCII, `ſ` = `s`, `K` = `k`.

Убранные параметры видны в диагностике импорта по имени, без значений.

## Маршрутизация и DNS

- **TUN.** Адреса IPv4 `172.19.0.1/30` и IPv6 `fdfe:dcba:9876::1/126`, маршруты по
  умолчанию `0.0.0.0/0` и `::/0`, MTU 1500. IPv6-трафик не обходит туннель.
- **DNS.** Системный резолвер направлен на `172.19.0.2` внутри туннеля. Запросы на порт 53
  перехватываются в outbound `dns` и разрешаются по порядку через `https://1.1.1.1/dns-query`,
  `https://8.8.8.8/dns-query`, затем `8.8.8.8` (UDP) — всё через прокси. Используются только
  A-записи (`UseIPv4`). В JSON-конфигах — DNS и правила провайдера.
- **Частные сети** (`10/8`, `100.64/10`, `127/8`, `169.254/16`, `172.16/12`, `192.168/16`,
  `::1`, `fc00::/7`, `fe80::/10`) идут напрямую. Остальное — через первый outbound.
- **Имена VPN-серверов** расширение разрешает системным DNS текущей сети до применения
  сетевых настроек туннеля: параллельно, до 16 одновременно, не дольше 5 с. SNI/Host
  закрепляются именем.
- **Kill switch не реализован** (`includeAllNetworks` выключен): если туннель упал, трафик
  идёт напрямую.

## Виджет

Small-виджет: кнопка питания и статус («Нет сервера», «Отключено», «Подключение…»,
«Подключено», «Отключение…», «Ошибка подключения»). Статус всегда вычисляется из
`NEVPNStatus`.

- **Кнопка — `ToggleVPNIntent`.** Это `LiveActivityIntent`, поэтому `perform()` выполняется
  в процессе приложения в фоне, без вывода на передний план. На iOS 26+ дополнительно задан
  `supportedModes = .background`.
- **Идемпотентность.** Направление (подключить / отключить) фиксируется при отрисовке, а
  `TunnelCommand.action` перепроверяет реальный статус, поэтому двойное нажатие не
  переключит VPN обратно.
- **Пока VPN-конфигурации нет** (первое подключение) или её не удалось прочитать, нажатие
  открывает приложение через `monovpn://connect`. Приложение показывает экран «Перед
  подключением» и системный запрос.
- **Сервер.** Виджет подключает последний выбранный сервер: его конфигурация лежит в общем
  Keychain.
- **Обновление.** Перерисовку запрашивают приложение, App Intent и Packet Tunnel; постоянного
  опроса нет.

## Данные и конфиденциальность

| Данные | Где | Защита |
|---|---|---|
| Ссылка на подписку, серверы, выбранный сервер, причины несовместимости | Keychain (`app-state.v1`) | `AfterFirstUnlockThisDeviceOnly`, без iCloud |
| Конфигурация туннеля выбранного сервера | Keychain (`tunnel-configuration.v1`), общая access group | то же |
| Очищенные тексты последней ошибки туннеля и виджета | Keychain (`last-tunnel-error.v1`, `widget-error.v1`) | то же |
| Конфиги JSON-подписки | `Application Support/panel-configurations.json` | `completeUntilFirstUserAuthentication`, без резервного копирования |
| Флаги «экран конфиденциальности принят», «очистка выполнена» | `UserDefaults` приложения | без данных пользователя |

- **Журналы не ведутся.** Журнал Xray выключен, файлов диагностики нет, `os.Logger` только
  в DEBUG-сборке и без адресов, ссылок и учётных данных.
- **Тексты ошибок** очищаются от UUID, ключей, URL и IP (`TunnelErrorSanitizer`).
- **Данные прежних версий.** `LegacyDiagnosticsCleanup` при первом запуске удаляет файлы
  диагностики, настройку подробного журнала и поля отчётов в Keychain, оставшиеся от прежних
  сборок. Если контейнер App Group или Keychain недоступны, очистка повторяется при следующем
  запуске.
- **«Удалить подписку»** удаляет подписку, конфиги, конфигурацию туннеля и тексты ошибок.
  Записи Keychain в iOS могут пережить удаление приложения, поэтому подписку стоит удалить
  до удаления приложения.
- **Сетевые обращения приложения** — только к адресу подписки. VPN-трафик идёт к серверу
  провайдера, DNS — через него к Cloudflare/Google или к DNS провайдера.

Политика конфиденциальности: <https://irklch.github.io/monovpn-site/privacy/> (ссылка в листе
«Подписка» и на экране «Перед подключением»). Сверка политики с кодом и оценка App Privacy —
в [docs/app-store-privacy.md](docs/app-store-privacy.md).

### Privacy Manifest

| Target | Категория | Причина |
|---|---|---|
| MonoVPN | UserDefaults | `CA92.1`, `1C8F.1` |
| PacketTunnel | FileTimestamp | `C617.1` (рантайм Go в libXray) |
| PacketTunnel | SystemBootTime | `35F9.1` (рантайм Go в libXray) |
| MonoVPNWidget | — | — |

Во всех трёх манифестах `NSPrivacyTracking = false` и пустой `NSPrivacyCollectedDataTypes`.
Причины для PacketTunnel основаны на проверке darwin/arm64-сборки тех же исходников и
подтверждаются на собранном iOS-архиве:

```bash
MonoVPN/Scripts/check-privacy-manifests.sh <archive>.xcarchive Frameworks/LibXray.xcframework
```

## Лицензии

- **Состав.** Сторонний код — только libXray и его Go-зависимости, статически слинкованные в
  PacketTunnel: 48 модулей Go и стандартная библиотека Go.
- **Лицензии:** MPL-2.0 (Xray-core, REALITY, gopher-luar), LGPL-3.0 со static linking
  exception (juju/ratelimit), Apache-2.0, BSD, MIT. GPL-кода в сборке нет.
- **Где показаны.** Полные тексты, уведомления об авторских правах и ссылки на исходный код
  использованных версий — на экране «Подписка → Лицензии» и в
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- **Копия исходников.** Точные архивы компонентов под MPL-2.0 и libXray хранятся в
  [third_party/sources](third_party/sources/README.md), с SHA-256 и проверкой по `go.sum`.
- **Обновление.** После смены версий libXray / Xray-core:
  1. Обновите копию исходников:
     ```bash
     MonoVPN/Scripts/mirror-third-party-sources.sh
     ```
  2. Закоммитьте `third_party/sources`.
  3. Перегенерируйте уведомления:
     ```bash
     MonoVPN/Scripts/generate-third-party-notices.sh
     ```

Разбор обязательств при распространении через App Store — в [docs/licensing.md](docs/licensing.md).

## Публикация в App Store

1. **Аккаунт.** Guideline 5.4: VPN-приложения публикуются разработчиком, зарегистрированным
   как организация. С Individual-аккаунтом публикация, скорее всего, будет отклонена.
2. **App Store Connect:**
   - Privacy Policy URL — <https://irklch.github.io/monovpn-site/privacy/>;
   - Support URL — `…/monovpn-site/support/`;
   - App Privacy — «Data Not Collected», Tracking — No (обоснование в
     [docs/app-store-privacy.md](docs/app-store-privacy.md)).
3. **Export Compliance.** В `App-Info.plist` задан `ITSAppUsesNonExemptEncryption = YES`.
   Ответы на вопросы и решение по Франции — в [docs/export-compliance.md](docs/export-compliance.md).
4. **Регионы.** Исключить China mainland; принять решение по России и Франции.
5. **App Review Notes** на английском:
   - тестовая подписка с долгим сроком действия;
   - пояснение, что это клиент для подписок сторонних провайдеров, без своих серверов и сбора
     данных, на `NETunnelProviderManager`.
6. **Архив и проверка.**
   - Увеличить `CURRENT_PROJECT_VERSION` для каждой загрузки.
   - Archive для «Any iOS Device (arm64)».
   - Запустить проверку манифестов:
     ```bash
     MonoVPN/Scripts/check-privacy-manifests.sh <archive>.xcarchive Frameworks/LibXray.xcframework
     ```
   - Затем Distribute App → App Store Connect.

## Известные ограничения

- Kill switch нет; после падения туннеля трафик идёт напрямую. iOS может оставить уже
  установленные TCP-соединения вне туннеля, часть служб Apple может обходить VPN.
- Одна подписка; автоматического обновления по расписанию нет.
- Память Packet Tunnel ограничена iOS (~50 МБ); libXray на iOS сам ограничивает память Go.
- Только русская локализация; структура String Catalog готова для других языков.
- Тексты ошибок ядра — на английском, они приходят из Xray.
- Записи Keychain могут сохраниться после удаления приложения, если подписку не удалили.

## Чек-лист ручного тестирования

**Подписка**
- [ ] Импорт HTTPS-подписки (ссылки, Base64), JSON-подписки панели и одиночной `vless://`.
- [ ] HTTP-ссылка, мусорный текст, Clash YAML → понятная ошибка, текущая подписка не меняется.
- [ ] Обновление в режиме полёта → ошибка, серверы и выбор сохранены.
- [ ] Полная ссылка подписки нигде не отображается (только домен).
- [ ] Удаление подписки при активном VPN: подтверждение → VPN отключается → серверы исчезают.
- [ ] Конфиг с Lua-скриптом или полем в двух написаниях → сервер в «Не распознаны» с причиной.

**Подключение**
- [ ] Первое подключение: экран «Перед подключением» (ссылка на политику открывается) →
      системный запрос VPN; отказ → понятная ошибка.
- [ ] Статусы и таймер; повторные быстрые нажатия не ломают состояние.
- [ ] Неверный сервер → ошибка, нет ложного «Подключено».
- [ ] VLESS REALITY, VLESS TLS (WS/gRPC/XHTTP), VMess, Trojan, Shadowsocks, сервер из JSON-подписки.
- [ ] Смена сервера при подключении → переподключение к новому серверу.

**Фон, сеть, виджет**
- [ ] Блокировка экрана 10+ минут, Wi-Fi ↔ сотовая, режим полёта, перезагрузка → подключение из «Настроек».
- [ ] Виджет: подключение/отключение при закрытом приложении, двойное нажатие, «Нет сервера» без подписки.
- [ ] Первое подключение из виджета открывает приложение и показывает экран «Перед подключением».

**Конфиденциальность и юридическое**
- [ ] ipleak.net / dnsleaktest.com: IP и DNS — не провайдера сети; test-ipv6.com — нет реального IPv6.
- [ ] Console.app у Release-сборки: нет сообщений subsystem `com.irklch.monovpn`.
- [ ] «Подписка → Политика конфиденциальности» открывает страницу; «Лицензии» — список
      компонентов, тексты раскрываются, ссылки на исходный код открываются.
- [ ] Обновление со сборки прежней версии: файлов `Tunnel/diagnostics.json` и `Tunnel/xray-error.log` нет.
