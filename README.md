# Mono VPN

Минималистичный VPN-клиент для iOS. Пользователь вставляет ссылку подписки, выбирает сервер и нажимает Play. Собственных серверов, backend, аналитики, авторизации у приложения нет: оно подключается к серверам стороннего провайдера из подписки пользователя.

- Платформа: iOS 17.0+, iPhone, портретная ориентация.
- Стек: Swift, SwiftUI, MVVM, Swift Concurrency, NetworkExtension (`NETunnelProviderManager` + `NEPacketTunnelProvider`), Keychain, App Groups.
- VPN Core: [sing-box](https://github.com/SagerNet/sing-box) **v1.14.4** (Libbox, собирается локально в `Libbox.xcframework`).
- Сторонних Swift-зависимостей нет.

> **Ветка `feature/xray-core-migration` — Proof of Concept на Xray-core v26.11.9** (флаг сборки `MONO_CORE_XRAY`, `LibXray.xcframework` из `MonoVPN/Scripts/build-libxray.sh`). Сборка и проверка на iPhone — [docs/xray-poc-testing.md](docs/xray-poc-testing.md), план — [docs/xray-migration.md](docs/xray-migration.md). Описание ниже относится к реализации на sing-box, которая остаётся в репозитории до успешной проверки PoC.

> **Статус.** Код всех targets (приложение, Packet Tunnel, виджет) собирается для устройства (arm64, без подписи) и симулятора, unit-тесты проходят, конфигурации sing-box проходят `sing-box check`. **Реальное VPN-подключение и работа виджета не проверены:** для этого нужны платный Apple Developer аккаунт и физический iPhone (см. «Что проверить на iPhone»). До такой проверки VPN нельзя считать работающим.

---

## Содержание

1. [Архитектура](#архитектура)
2. [Сборка](#сборка)
3. [Интеграция VPN Core](#интеграция-vpn-core)
4. [Signing & Capabilities](#signing--capabilities)
5. [Запуск на физическом iPhone](#запуск-на-физическом-iphone)
6. [Internal TestFlight](#internal-testflight)
7. [Подписки и протоколы](#подписки-и-протоколы)
8. [Маршрутизация, DNS и утечки](#маршрутизация-dns-и-утечки)
9. [Виджет](#виджет)
10. [Иконка приложения](#иконка-приложения)
11. [Результаты технического ревью](#результаты-технического-ревью)
12. [Лицензионные требования](#лицензионные-требования)
13. [Известные ограничения](#известные-ограничения)
14. [Ограничения Apple для VPN-приложений](#ограничения-apple-для-vpn-приложений)
15. [Чек-лист ручного тестирования VPN](#чек-лист-ручного-тестирования-vpn)

---

## Архитектура

```
MonoVPN.xcodeproj
Frameworks/                  Libbox.xcframework (собирается скриптом, в git не хранится)
MonoVPN/
├── App/                     MonoVPNApp — точка входа, обработка scenePhase
├── Core/
│   ├── VPN/                 VPNManager, VPNConfigurationBuilder, ConnectionDurationFormatter
│   ├── Networking/          SubscriptionService (загрузка подписки, ошибки сети)
│   ├── Storage/             AppStateStore (Keychain), Preferences (несекретные флаги)
│   └── Parsing/             SubscriptionParser, ProxyLinkParser
├── Models/                  ServerConfiguration, Subscription, AppState
├── Features/
│   ├── Home/                HomeView, HomeViewModel
│   ├── Servers/             ServersView (sheet «Серверы»)
│   ├── Subscription/        SubscriptionView (sheet «Подписка»)
│   └── Privacy/             PrivacyNoticeView (перед первым подключением)
├── DesignSystem/            Палитра, стили кнопок, общие компоненты
├── Resources/               Assets.xcassets, Localizable.xcstrings
├── Shared/                  Код и строки для приложения и extensions: AppIdentifiers, SecureStorage, TunnelController, WidgetCommand, Tunnel.xcstrings
├── PacketTunnel/            PacketTunnelProvider, TunnelPlatformInterface (мост Libbox ↔ NetworkExtension)
├── Widget/                  Виджет Home Screen и App Intent
├── Config/                  Identifiers.xcconfig, Info.plist, entitlements
├── Scripts/                 build-libbox.sh
└── Tests/                   Unit-тесты (Swift Testing)
```

Папки подключены к Xcode как синхронизируемые группы (Xcode 16+): новые файлы в папке автоматически попадают в нужный target.

| Target | Тип | Папки |
|---|---|---|
| `MonoVPN` | приложение | App, Core, Models, Features, DesignSystem, Resources, Shared |
| `PacketTunnel` | Packet Tunnel Provider extension (встраивается в приложение) | PacketTunnel, Shared + Libbox.xcframework, NetworkExtension, UIKit, libresolv |
| `MonoVPNWidget` | Widget Extension (встраивается в приложение) | Widget, Shared |
| `MonoVPNTests` | unit-тесты (host — приложение) | Tests |

### Ответственность компонентов

- **SubscriptionParser** — разбирает тело подписки: список ссылок (plain text или Base64, стандартный и URL-safe). Clash YAML, JSON и HTML распознаются и отклоняются с понятной ошибкой. Неподдерживаемые записи не теряются молча — они попадают в `issues` и показываются пользователю.
- **ProxyLinkParser** — разбирает `vless://`, `vmess://`, `trojan://`, `ss://`, валидирует UUID, порт, ключ REALITY и т. д. Параметры, которые sing-box не поддерживает, либо делают ссылку невалидной (если без них подключение будет не тем, что задумал провайдер), либо попадают в `ignoredParameters` и показываются в списке серверов.
- **SubscriptionService** — валидирует ввод (только HTTPS, либо отдельная ссылка), загружает подписку через эфемерную `URLSession` (без кэша и cookies), переводит ошибки сети в понятные сообщения. При ошибке ничего не меняет — последняя корректная конфигурация сохраняется.
- **VPNConfigurationBuilder** — строит JSON-конфигурацию sing-box 1.14 для выбранного сервера.
- **SecureStorage / AppStateStore** — Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, общая access group). Подписка, серверы и выбранный сервер хранятся одним Keychain-элементом. В `UserDefaults` — только флаг «экран конфиденциальности показан».
- **VPNManager** (`@MainActor @Observable`) — владеет `NETunnelProviderManager`, подписан на `NEVPNStatusDidChange` и `NEVPNConfigurationChange`. Состояние подключения — это всегда `NEVPNStatus` (Invalid / Disconnected / Connecting / Connected / Reasserting / Disconnecting), а не локальный Boolean. Время подключения — `connection.connectedDate`.
- **HomeViewModel** — сценарии экрана: подключение/отключение с защитой от повторных нажатий, смена сервера (остановка туннеля → ожидание `.disconnected` → запуск с новой конфигурацией), импорт/обновление/удаление подписки (с предварительным отключением VPN).
- **PacketTunnelProvider** — читает готовую конфигурацию из общего Keychain, инициализирует Libbox (`LibboxSetup`), создаёт `LibboxCommandServer` и запускает сервис (`startOrReloadService`). Конфигурация берётся из Keychain, а не из `startVPNTunnel(options:)`, поэтому туннель может перезапустить и система, и пользователь из «Настроек», в том числе при заблокированном экране.
- **TunnelPlatformInterface** — реализация `LibboxPlatformInterface`: настраивает `NEPacketTunnelNetworkSettings` (адреса, маршруты IPv4/IPv6, DNS) по запросу ядра, отдаёт ядру дескриптор TUN, отслеживает смену сети через `NWPathMonitor` (Wi-Fi ↔ сотовая сеть).

### Секундомер

`TimelineView(.periodic(by: 1))` каждую секунду пересчитывает `now − connectedDate`. Фонового `Timer` и накопления времени нет, поэтому значение верно после сворачивания и перезапуска приложения (статус и дата перечитываются при каждом возврате в foreground). При любом статусе, кроме Connected, показывается `00:00:00`.

---

## Сборка

### Требования

- macOS с Xcode 16 или новее (проверено на Xcode 27.0, iOS SDK 27.0).
- Go ≥ 1.25 (`brew install go`) — только для сборки VPN Core; нужная версия toolchain (`go1.26.10`) скачивается самим `go`.
- git.

### Шаги

```bash
MonoVPN/Scripts/build-libbox.sh
```

```bash
open MonoVPN.xcodeproj
```

Проверка сборки без подписи (так проверялся проект):

```bash
xcodebuild -project MonoVPN.xcodeproj -scheme MonoVPN -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Unit-тесты (нужен срез симулятора в Libbox — скрипт по умолчанию собирает его):

```bash
xcodebuild test -project MonoVPN.xcodeproj -scheme MonoVPN -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MonoVPNTests CODE_SIGNING_ALLOWED=NO
```

---

## Интеграция VPN Core

### Выбор и проверка

| Вопрос | Результат |
|---|---|
| Версия | sing-box **v1.14.4** (последний стабильный тег на момент интеграции), commit `c005f35300ce76427dc285481ec5695f5b179cd2` |
| iOS 17+ | Libbox собирается с `-iosversion=15.0`, приложение — iOS 17.0 |
| Packet Tunnel Provider | Да: тот же подход, что у официального клиента sing-box-for-apple (`LibboxCommandServer` + `LibboxPlatformInterface`) |
| Сборка для iOS | `gomobile bind` (форк `github.com/sagernet/gomobile` v0.1.13) → `Libbox.xcframework` (статический фреймворк, встраивать не нужно) |
| arm64 (устройство) | Да: срез `ios-arm64`; плюс `ios-arm64_x86_64-simulator` для тестов |
| Протоколы | VLESS (+ REALITY, TLS, Vision), VMess, Trojan, Shadowsocks (AEAD и 2022) |
| Память Network Extension | iOS ограничивает память packet tunnel (~50 МБ). Сборка с тегом `with_low_memory`, включён OOM-killer Libbox; размер бинарника extension ~55 МБ (это не потребление памяти, но проверить реальное потребление нужно на устройстве) |
| App Store / TestFlight | Технических препятствий нет (официальный клиент sing-box распространяется через App Store), **но есть лицензионный вопрос** — см. «Лицензионные требования» |
| Лицензия | GPL-3.0-or-later + дополнительное условие об имени (см. ниже) |

API Libbox не придуман: код extension написан по заголовку `Libbox.objc.h`, сгенерированному из исходников v1.14.4, и сверен с реализацией sing-box-for-apple. При смене версии sing-box API может измениться — пересоберите и исправьте ошибки компиляции.

### Воспроизводимость

`MonoVPN/Scripts/build-libbox.sh` фиксирует:

- тег и commit sing-box (при несовпадении commit сборка прерывается);
- версию gomobile/gobind (`v0.1.13`);
- Go toolchain через `GOTOOLCHAIN=go1.26.10` (как в CI sing-box);
- build tags: `with_gvisor,with_utls,with_low_memory,badlinkname,tfogo_checklinkname0` — только то, что нужно (REALITY требует uTLS); без naive/cronet, QUIC, WireGuard, Tailscale-эндпоинтов;
- флаги линковщика как в `cmd/internal/build_shared` апстрима.

Результат: `Frameworks/Libbox.xcframework` и `Frameworks/LIBBOX_VERSION`. Бинарник (~200 МБ со срезом симулятора) не коммитится. Только для устройства (быстрее):

```bash
PLATFORMS=ios MonoVPN/Scripts/build-libbox.sh
```

### Подключение в Xcode

Уже сделано в проекте: `Frameworks/Libbox.xcframework` линкуется только в target `PacketTunnel` (вместе с `NetworkExtension.framework`, `UIKit.framework` и `libresolv.tbd`, которые требуются Go-рантайму). Встраивать (Embed) фреймворк не нужно — он статический.

---

## Signing & Capabilities

В targets указана **личная** команда владельца (Individual), выбранная в Xcode → Signing & Capabilities. Команда работодателя не используется. Сменить команду можно вручную в Xcode для каждого target.

Все идентификаторы — в одном месте: `MonoVPN/Config/Identifiers.xcconfig`.

| Параметр | Значение |
|---|---|
| Display Name | Mono VPN |
| App Bundle ID | `com.irklch.monovpn` |
| Packet Tunnel Bundle ID | `com.irklch.monovpn.PacketTunnel` |
| Widget Bundle ID | `com.irklch.monovpn.Widget` |
| App Group | `group.com.irklch.monovpn` |
| Keychain Sharing group | `$(AppIdentifierPrefix)com.irklch.monovpn.shared` |
| Signing | Automatic, личная команда в настройках targets (`DEVELOPMENT_TEAM` в xcconfig пуст) |

Info.plist всех targets получают значения из xcconfig, Swift-код читает их из Info.plist (`AppIdentifiers`). Если идентификатор занят — поменяйте его только в xcconfig.

### Entitlements

`MonoVPN/Config/MonoVPN.entitlements`, `MonoVPN/Config/PacketTunnel.entitlements` и `MonoVPN/Config/Widget.entitlements` (одинаковые):

```xml
<key>com.apple.developer.networking.networkextension</key>
<array><string>packet-tunnel-provider</string></array>
<key>com.apple.security.application-groups</key>
<array><string>$(MONO_APP_GROUP)</string></array>
<key>keychain-access-groups</key>
<array><string>$(AppIdentifierPrefix)$(MONO_BUNDLE_ID).shared</string></array>
```

Виджету Network Extensions → Packet Tunnel нужен потому, что его App Intent вызывает `NETunnelProviderManager` в собственном процессе. Одного entitlement недостаточно: см. «Виджет» → fallback через приложение.

### После активации личного Apple Developer Program

1. Xcode → Settings → Accounts: добавьте **свой** Apple ID и выберите **личную** команду (не команду работодателя).
2. Укажите Team ID: либо `DEVELOPMENT_TEAM = XXXXXXXXXX` в `Identifiers.xcconfig`, либо в Xcode → target → Signing & Capabilities для **всех трёх** targets (`MonoVPN`, `PacketTunnel`, `MonoVPNWidget`).
3. При Automatic Signing Xcode сам зарегистрирует App ID для всех Bundle ID, App Group и Keychain Sharing group в вашей команде. Проверьте на вкладке Signing & Capabilities, что у всех трёх targets есть:
   - **Network Extensions** → Packet Tunnel;
   - **App Groups** → `group.com.irklch.monovpn`;
   - **Keychain Sharing** → `com.irklch.monovpn.shared`.
4. Если Xcode не раскрывает переменные в entitlements при создании профиля, замените `$(MONO_APP_GROUP)` на литерал `group.com.irklch.monovpn`.

Без подписи (`CODE_SIGNING_ALLOWED=NO`) проект собирается целиком — так ведётся разработка до появления аккаунта.

---

## Запуск на физическом iPhone

Packet Tunnel **не работает в симуляторе** — VPN проверяется только на устройстве.

1. Выполните шаги из «Signing & Capabilities».
2. На iPhone включите «Режим разработчика» (Настройки → Конфиденциальность и безопасность).
3. Подключите iPhone, выберите его в Xcode и запустите схему `MonoVPN` (⌘R).
4. В приложении: «Добавить подписку» → вставьте ссылку → «Сохранить» → Play → подтвердите системный запрос «Добавить конфигурацию VPN».
5. Логи extension: Console.app → устройство → фильтр `subsystem:com.irklch.monovpn`. Секреты и ссылки не логируются.
6. Отладка extension: Debug → Attach to Process → `PacketTunnel` (после первого запуска туннеля).

---

## Internal TestFlight

Выполняется владельцем вручную — загрузки в App Store Connect из этого проекта не производились.

1. Перед загрузкой:
   - решите лицензионный вопрос (см. ниже) — бинарник, переданный тестировщикам, уже является распространением GPL-кода;
   - увеличьте `CURRENT_PROJECT_VERSION` в `Identifiers.xcconfig` для каждой новой сборки.
2. App Store Connect → My Apps → «+» → New App с Bundle ID `com.irklch.monovpn`.
3. Xcode: схема `MonoVPN`, destination «Any iOS Device (arm64)» → Product → Archive → Distribute App → App Store Connect → Upload.
4. Export Compliance: приложение использует шифрование (TLS/VPN-протоколы). Ответьте на вопросы в App Store Connect; при необходимости добавьте `ITSAppUsesNonExemptEncryption` в `App-Info.plist`.
5. TestFlight → Internal Testing → добавьте себя в группу. Internal TestFlight не требует App Review.

---

## Подписки и протоколы

### Форматы подписок

| Формат | Поддержка |
|---|---|
| HTTPS URL, тело — список ссылок по одной в строке | ✅ |
| HTTPS URL, тело — Base64 (стандартный или URL-safe, с/без padding) списка ссылок | ✅ (формат 3x-ui, Marzban, Remnawave и др. для «обычных» клиентов) |
| Одна ссылка `vless://` / `vmess://` / `trojan://` / `ss://`, вставленная вместо URL | ✅ |
| HTTP (без TLS) | ❌ отклоняется: токен подписки может быть перехвачен |
| Clash / Mihomo YAML, sing-box / Xray JSON, HTML | ❌ распознаётся и отклоняется с сообщением |

Запрос подписки отправляется с `User-Agent: MonoVPN/<версия>`. Строки-комментарии (`#`, `//`) и дубликаты пропускаются. Количество серверов не ограничено.

Все распознанные серверы показываются в списке. Серверы, которые подключённое ядро не умеет запускать, неактивны и подписаны «Не поддерживается»; выбрать их нельзя, транспорт другим не подменяется. Подробности (почему сервер не поддерживается, нераспознанные записи, неприменённые параметры) — в «Подписка → Диагностика импорта». Там показываются только имена серверов, названия протоколов/транспортов и имена параметров: без UUID, паролей, значений параметров и URL подписки.

### Протоколы

| Протокол | Транспорты | Безопасность |
|---|---|---|
| **VLESS** | TCP (RAW; `headerType` пустой/`none`), WebSocket (включая early data `?ed=`), gRPC (gun; `authority` = SNI), HTTP/2, HTTPUpgrade | none, TLS, **REALITY**; flow `xtls-rprx-vision` |
| **VMess** (v2rayN JSON) | те же | none, TLS |
| **Trojan** | те же | TLS (по умолчанию), REALITY |
| **Shadowsocks** (SIP002 и legacy) | TCP/UDP; плагины `obfs-local`/`simple-obfs`, `v2ray-plugin` (websocket) | `2022-blake3-*`, `aes-128/192/256-gcm`, `(x)chacha20-ietf-poly1305` |

«Не поддерживается» (ограничение sing-box 1.14.4, сервер виден в списке, но неактивен): XHTTP/SplitHTTP (в ядре нет такого транспорта), mKCP, QUIC-транспорт (в сборке нет тега `with_quic`), TCP `headerType=http`, gRPC `authority`, отличающийся от SNI (gRPC lite не умеет задавать их раздельно), VLESS `encryption` ≠ `none`, flow кроме `xtls-rprx-vision`, Vision без TLS/TCP, прочие плагины Shadowsocks и `v2ray-plugin` с `mode=quic`, потоковые шифры Shadowsocks.

Не распознаются (только в диагностике): битые ссылки и схемы Hysteria/TUIC/WireGuard и прочие.

В диагностике как «Частично применены» (сервер поддерживается): `allowInsecure` (проверка сертификата **никогда** не отключается), `spx` (spiderX REALITY), неизвестный `fp` (заменяется на `chrome`), gRPC `mode=multi` (multi-сервер Xray принимает gun), любые неизвестные параметры.

Страна сервера не определяется и не угадывается — показываются только имя из конфигурации и протокол.

### Диагностика обновлений подписки

При каждом импорте и обновлении ответ провайдера сравнивается с предыдущим ответом того же источника. Последние 10 отчётов видны в «Подписка → Диагностика импорта → Обновления подписки» (текст можно выделить и скопировать) и пишутся в системный журнал (Console.app, subsystem `com.irklch.monovpn`, категория `SubscriptionDiagnostics`).

В отчёте: хеш SHA-256 ответа (первые 16 байт) и его размер; изменился ли ответ (не изменился / только порядок строк / изменилось содержимое); всего серверов, поддерживаемых, неподдерживаемых, с ошибками, дубликатов и повторяющихся имён; распределения по протоколам, транспортам, режимам безопасности и причинам несовместимости; добавлено / удалено / изменено; смены статуса совместимости с именами изменившихся параметров ссылки (`sni`, `authority`, `type`, `address`, `credentials`, ...). Значения параметров, UUID, пароли, ключи, адреса и URL подписки не выводятся: внутри снимка (он хранится в Keychain вместе с подпиской) лежат только хеши значений. В журнале имена серверов помечены как private.

Как читать: если «Ответ провайдера не изменился», а статусы изменились — это ошибка в приложении (отчёт так и скажет); если ответ изменился и у сменивших статус серверов изменился `sni`/`authority`/`type` — провайдер отдаёт разные ссылки на каждый запрос (например, случайный SNI из пула). Каждая ссылка дополнительно разбирается дважды: «Недетерминированный разбор» > 0 означал бы ошибку парсера.

Выбранный сервер сохраняется, даже если провайдер изменил его ссылку (ID сервера — хеш ссылки): выбор переносится на сервер с тем же протоколом, именем, адресом и портом. Импорт и обновление подписки не выполняются одновременно, а результат обновления, завершившегося после удаления подписки, отбрасывается.

План перехода на Xray-core — в [docs/xray-migration.md](docs/xray-migration.md).

---

## Маршрутизация, DNS и утечки

Конфигурация sing-box (см. `VPNConfigurationBuilder`):

- TUN с адресами IPv4 (`172.19.0.1/30`) **и IPv6** (`fdfe:dcba:9876::1/126`), `auto_route`, `strict_route` → extension устанавливает маршруты по умолчанию `0.0.0.0/0` и `::/0`. IPv6-трафик не обходит туннель, даже если у VPN-сервера нет IPv6 (такие соединения просто не устанавливаются).
- DNS: системный резолвер направлен на адрес внутри TUN, sing-box перехватывает все DNS-запросы (`hijack-dns`) и отправляет их по DNS-over-HTTPS в `1.1.1.1` **через прокси**. Провайдер сети не видит DNS-запросы; Cloudflare видит их с IP VPN-сервера. Это упомянуто на экране конфиденциальности.
- Адрес самого VPN-сервера (если это домен) резолвится системным резолвером вне туннеля — иначе подключиться невозможно.
- Частные сети (LAN, `ip_is_private`) идут напрямую.
- Логи ядра: уровень `warn`, только в памяти extension, на диск не пишутся.

**Не реализовано и не проверено:**

- Kill switch: если туннель упал или выключен, трафик идёт напрямую. `includeAllNetworks` не включён (он ломает часть системных сервисов и требует отдельной проверки).
- iOS может оставить уже установленные до подключения TCP-соединения вне туннеля, а часть служб Apple может обходить VPN.
- Отсутствие утечек DNS/IPv6 на реальном устройстве **не проверено** — см. чек-лист.

---

## Виджет

Small-виджет на Home Screen: кнопка питания по центру и статус под ней. Фон `#171717`, монохромная иконка `power`, без градиентов и акцентных цветов. В режимах оформления Home Screen (тёмный / тонированный / StandBy) кнопка помечена `widgetAccentable()`, цвета зависят от `widgetRenderingMode`.

### Архитектура

```
MonoVPN/Widget/ConnectionWidget.swift    WidgetBundle, ConnectionWidget, ConnectionProvider, ToggleVPNIntent, ConnectionWidgetView
MonoVPN/Widget/Localizable.xcstrings     строки виджета (ru)
MonoVPN/Shared/TunnelController.swift    общие операции NetworkExtension (app + виджет): load / install / start / stop / waitForStatus
MonoVPN/Shared/WidgetCommand.swift       TunnelCommand (connect / disconnect), WidgetVPNState, WidgetCommandRunner
```

Второго VPN-менеджера нет: `VPNManager` (приложение) и App Intent виджета вызывают один и тот же `TunnelController`. `HomeViewModel` и `VPNManager` в виджет не входят — они `@MainActor`, зависят от UI и в процессе виджета не существуют.

| Target | Тип | Папки |
|---|---|---|
| `MonoVPNWidget` | Widget Extension (встраивается в приложение), Bundle ID `com.irklch.monovpn.Widget` | Widget, Shared |

### Как это работает

1. **Статус.** `ConnectionProvider.getTimeline` при каждой перезагрузке читает реальный `NEVPNStatus` (`TunnelController.loadManager()`), наличие конфигурации выбранного сервера и последнюю ошибку из Keychain → `WidgetVPNState`: «Нет сервера», «Отключено», «Подключение…», «Подключено», «Отключение…», «Ошибка подключения». Ничего не хранится и не угадывается — «Подключено» показывается только при `NEVPNStatus.connected`.
2. **Нажатие.** Кнопка — `Button(intent: ToggleVPNIntent(connect:))`. Направление (подключить / отключить) задаётся при отрисовке по текущему статусу. В iOS 17 `perform()` интерактивного виджета выполняется **в процессе Widget Extension**, без открытия приложения.
3. **Выполнение.** `WidgetCommandRunner.perform` заново читает статус и через `TunnelCommand.action` решает, что делать: `connect` запускает туннель только из Disconnected/Invalid, `disconnect` останавливает только Connecting/Connected/Reasserting. Повторное или двойное нажатие ничего не переключает обратно.
4. **Запуск.** `startVPNTunnel()` → система запускает Packet Tunnel (отдельный процесс), который берёт конфигурацию из общего Keychain. Intent ждёт подтверждения системы (`NEVPNStatusDidChange`, не дольше 10 с) и запрашивает перезагрузку виджета.
5. **Синхронизация.** `WidgetCenter.reloadTimelines(ofKind:)` вызывают: App Intent после выполнения, `VPNManager` при каждой смене статуса, `HomeViewModel` при смене сервера/подписки, Packet Tunnel при старте, ошибке и остановке (то есть и при переключении из «Настроек», когда приложение закрыто). Постоянного опроса нет; только в переходных состояниях таймлайн просит одну повторную перезагрузку через 5 с. Приложение при открытии перечитывает статус из системы, поэтому VPN, включённый из виджета, отображается корректно.

### Последний выбранный сервер

Приложение держит в Keychain (`tunnel-configuration.v1`, общая access group) готовую конфигурацию sing-box **выбранного** сервера и обновляет её при выборе сервера, импорте/обновлении подписки и при запуске приложения; при удалении подписки элемент удаляется. Виджет сервер не выбирает: есть этот элемент — подключается именно с ним, нет — показывает «Нет сервера» и не подключается. Packet Tunnel читает тот же элемент.

### Ограничения фонового исполнения

- **Первое подключение — только из приложения.** Создание VPN-конфигурации показывает системный запрос разрешения, его нельзя показать из виджета. Пока конфигурации нет (`needsSetup`), нажатие на виджет открывает приложение через `widgetURL` `monovpn://connect` (документированный механизм; Small-виджет поддерживает один URL на весь виджет). Приложение выполняет идемпотентную команду `connect` (при необходимости сначала экран конфиденциальности). Если VPN уже подключён, команда ничего не делает.
- После того как конфигурация создана, виджет пытается подключать и отключать VPN **без открытия приложения**: App Intent в процессе Widget Extension вызывает `NETunnelProviderManager.loadAllFromPreferences()` → `startVPNTunnel()` / `stopVPNTunnel()`. Тот же приём использует официальный sing-box-for-apple (`WidgetExtension/WidgetTunnelControl.swift`). Документация Apple описывает `loadAllFromPreferences` как чтение конфигураций «вызывающего приложения», поэтому прямое управление из процесса виджета **на устройстве не подтверждено**.
- **Fallback через приложение.** `TunnelController.lookupManager()` различает три исхода: конфигурация найдена; чтение удалось, но конфигурации нет (`needsSetup` → «Настройте в приложении»); чтение не удалось (`unavailable` → «Откройте приложение», отказ в доступе `NEVPNError.configurationReadWriteFailed` или системная ошибка). В `needsSetup` и `unavailable` нажатие открывает приложение через `widgetURL` `monovpn://connect`, и подключение выполняет основное приложение. Статус в этих состояниях неизвестен, поэтому «Подключено» не показывается.
- **Ошибки команды.** Ошибка запуска, остановки (таймаут) или чтения конфигурации сохраняется в Keychain (`widget-error.v1`) → «Ошибка подключения». Ошибка сбрасывается после подтверждённого `.connected` (виджетом или приложением).
- **Повторные нажатия.** В процессе виджета команды сериализуются (`WidgetCommandGate`): нажатие во время выполнения предыдущего игнорируется. Межпроцессной блокировки между приложением и виджетом NetworkExtension не даёт, поэтому перед каждым действием перечитывается реальный `NEVPNStatus`: уже поднятый туннель повторно не запускается, отключающийся сначала дожидается `.disconnected`.
- Время выполнения App Intent ограничено системой; ожидание подтверждения — максимум 10 с.
- WidgetKit не гарантирует мгновенную перерисовку: возможна задержка в несколько секунд, у перезагрузок есть дневной бюджет.
- Недокументированные способы запуска приложения и обхода фоновых ограничений не используются.

### Подключение Widget Extension

Target уже есть в проекте и встраивается в приложение (Embed Foundation Extensions). После выбора своей команды (см. «Signing & Capabilities») проверьте у `MonoVPNWidget`:

- **App Groups** → `group.com.irklch.monovpn`;
- **Keychain Sharing** → `com.irklch.monovpn.shared` (виджету нужен доступ к конфигурации выбранного сервера и к ошибке туннеля);
- **Network Extensions** → Packet Tunnel (виджет вызывает `NETunnelProviderManager` сам; у sing-box-for-apple виджет обходится без этого entitlement, но мы не полагаемся на недокументированное поведение).

### Как добавить виджет на Home Screen

1. Установите приложение, добавьте подписку и **один раз подключитесь из приложения** (разрешите добавление VPN-конфигурации).
2. Долгое нажатие на пустом месте Home Screen → «Изменить» → «Добавить виджет».
3. Найдите Mono VPN, выберите маленький виджет → «Добавить виджет».

### Чек-лист тестирования виджета

- [ ] Без подписки: «Нет сервера», нажатие на кнопку не подключает.
- [ ] Подписка есть, VPN ни разу не подключался: «Отключено», нажатие открывает приложение и запускает подключение (после экрана конфиденциальности и системного запроса).
- [ ] Приложение закрыто (выгружено из переключателя): нажатие → «Подключение…» → «Подключено», приложение **не** открывается.
- [ ] Повторное нажатие → «Отключение…» → «Отключено».
- [ ] Двойное быстрое нажатие не переключает VPN обратно.
- [ ] Подключено из приложения → виджет показывает «Подключено» и отключает VPN.
- [ ] Прямое управление из виджета не работает (ошибка доступа к конфигурации) → «Откройте приложение», нажатие открывает приложение; «Подключено» не показывается.
- [ ] Смена сервера при активном VPN: если старый туннель не остановился, выбор сервера не меняется и показывается ошибка.
- [ ] Подключено из виджета → приложение при открытии показывает «Подключено» и верное время.
- [ ] Сменить сервер в приложении → подключение из виджета идёт к новому серверу.
- [ ] Неверный сервер → «Ошибка подключения», нет ложного «Подключено».
- [ ] VPN включён/выключен в «Настройки → VPN» → виджет обновился.
- [ ] Удаление подписки → «Нет сервера».
- [ ] Тёмный и тонированный режимы Home Screen, StandBy — кнопка и текст читаемы.
- [ ] Память и время ответа виджета (Xcode → Debug → Attach to Process → `MonoVPNWidget`).

---

## Иконка приложения

- **Источник:** утверждённый фрейм «AppIcon — 1024 × 1024» (node `1:6`) в Figma-файле `RZskmuzbaj8GxhoNVZjLU0`. Экспортирован через Figma MCP в PNG 1024 × 1024 как есть: фон `#171717`, белая строчная «m» и точка — так в утверждённом макете.
- Альфа-канал из экспорта удалён без изменения пикселей (все пиксели исходника непрозрачны), потому что App Store не принимает иконку с альфа-каналом. Углы не скруглены — это делает iOS.
- Файл: `MonoVPN/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` (единственный размер, остальные Xcode генерирует сам). Назначена target `MonoVPN` через `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`; в собранном приложении есть `CFBundleIconName = AppIcon`.

**Замена иконки:** экспортируйте новый фрейм 1024 × 1024 в PNG без прозрачности (sRGB, без скругления) и замените `AppIcon-1024.png` с тем же именем, `Contents.json` менять не нужно. Если в экспорте есть альфа-канал, уберите его (например, экспортом в JPEG и обратно в PNG или в редакторе) — иначе загрузка в App Store Connect завершится ошибкой.

---

## Результаты технического ревью

| # | Что проверено | Результат |
|---|---|---|
| 1 | Signing & Capabilities трёх targets | App: NE + App Groups + Keychain Sharing; PacketTunnel: то же; Widget: App Groups + Keychain Sharing. Team не указан |
| 2 | Раскрытие App Group и Keychain group | Значения из `Identifiers.xcconfig` попадают в entitlements и Info.plist. `$(AppIdentifierPrefix)` существует только в подписанной сборке; в неподписанной используется keychain самого процесса (общий доступ для VPN там и не нужен — NE без подписи не работает) |
| 3 | Совместный доступ к Keychain | Одна access group `<TEAM>.com.irklch.monovpn.shared` у всех трёх targets, `AfterFirstUnlockThisDeviceOnly` |
| 4 | Последний выбранный сервер | **Исправлено:** конфигурация выбранного сервера раньше попадала в Keychain только при подключении; теперь синхронизируется при выборе, обновлении подписки и запуске — виджет всегда стартует выбранный сервер |
| 5 | Восстановление `NETunnelProviderManager` | Поиск по `providerBundleIdentifier`. **Исправлено:** изменение статуса до загрузки менеджера (например, VPN включили из виджета) теперь вызывает загрузку |
| 6 | Конкурентные старт/стоп | Ожидание подтверждения отключения переведено с опроса каждые 200 мс на `NEVPNStatusDidChange`. **Исправлено:** удаление подписки могло не остановить VPN, если в этот момент выполнялось другое действие |
| 7 | Смена сервера во время подключения | Остановка → ожидание `.disconnected` → запуск с новой конфигурацией |
| 8 | Двойной запуск | В приложении `isPerformingAction` + блокировка в переходных состояниях; команды виджета идемпотентны |
| 9 | Ошибки Packet Tunnel | Ошибка старта сохраняется в Keychain и показывается в приложении и виджете; туннель перезагружает виджет при ошибке |
| 10 | Синхронизация виджета | Только `NEVPNStatus`, см. «Как это работает» |
| 11 | Локализация в виджете | **Исправлено:** тексты ошибок VPN перенесены в общую таблицу `Tunnel.xcstrings`, иначе в виджете были бы видны ключи. У виджета свой `Localizable.xcstrings` |
| 12 | Лицензия sing-box | Без изменений: GPL-3.0 остаётся блокером распространения (см. ниже). Логика виджета повторяет подход GPL-кода sing-box-for-apple |

---

## Лицензионные требования

**Это блокер для распространения, который должен решить владелец (желательно с юристом).**

- sing-box распространяется под **GPL-3.0-or-later** с дополнительным условием: производные работы не могут использовать имя sing-box или подразумевать связь с ним без согласия автора. Mono VPN не использует имя sing-box в названии и интерфейсе.
- Libbox статически линкуется в extension, а extension входит в приложение. Распространяемое приложение является производной работой → **всё приложение должно распространяться на условиях GPL-3.0, с предоставлением исходного кода** получателям (включая тестировщиков TestFlight).
- Совместимость GPL-3.0 с условиями App Store спорна (FSF считает дополнительные ограничения App Store несовместимыми с GPL; известен случай удаления VLC в 2011 году). То, что официальный клиент sing-box есть в App Store, не аргумент: его публикует сам правообладатель.
- `TunnelPlatformInterface` написан по образцу sing-box-for-apple (GPL-3.0).
- GPL-3.0 §5(d) требует показывать в интерактивном интерфейсе Appropriate Legal Notices — экрана лицензий в MVP нет, его нужно добавить до распространения.

Варианты:

1. **Открыть исходный код Mono VPN под GPL-3.0** (публичный репозиторий, файл LICENSE, экран лицензий) и принять риск, связанный с условиями App Store. Проще всего технически.
2. Получить у автора sing-box отдельную (коммерческую) лицензию.
3. Заменить ядро на проект с совместимой с закрытым кодом лицензией (например, Xray-core — MPL-2.0, файловый copyleft) — потребует новой интеграции и проверки.

Закрытый исходный код + App Store с текущим ядром — **не рекомендуется**.

---

## Известные ограничения

- VPN-подключение, работа в фоне и при заблокированном экране, смена сети, отсутствие утечек — **не проверены** (нет платного аккаунта и физического устройства в окружении разработки).
- Потребление памяти extension не измерено; лимит iOS для Packet Tunnel ~50 МБ.
- Одна подписка; автоматического обновления по расписанию нет (только вручную).
- Энергосбережение Libbox при выключенном экране (`pause`/`recordScreenState`) не подключено — туннель всегда активен.
- Виджет не проверен на устройстве: управление VPN из процесса Widget Extension, время отклика, работа при закрытом приложении. Отображение иконки на SpringBoard визуально не проверялось (проверено наличие в сборке).
- Английская локализация не добавлена: структура готова (String Catalog, `knownRegions` включает `en`), достаточно добавить переводы в `Resources/Localizable.xcstrings`, `Widget/Localizable.xcstrings` и `Shared/Tunnel.xcstrings`.
- Ошибка старта туннеля передаётся в приложение через общий Keychain; текст ошибок ядра — на английском.

---

## Ограничения Apple для VPN-приложений

- App Store Review Guideline **5.4**: приложения, предоставляющие VPN-сервисы, должны публиковаться разработчиком, зарегистрированным **как организация**. Публикация Mono VPN в App Store с Individual-аккаунта **не обещается** и, скорее всего, будет отклонена.
- VPN-приложения обязаны использовать `NEVPNManager` API, не продавать и не раскрывать пользовательские данные третьим лицам, иметь политику конфиденциальности (для App Store потребуется опубликованный URL политики).
- Возможность Network Extension (Packet Tunnel) требует платного членства в Apple Developer Program; бесплатный Personal Team её не даёт.
- Packet Tunnel Provider не запускается в iOS Simulator.
- Память Packet Tunnel extension ограничена системой (~50 МБ); при превышении iOS завершает extension.
- В некоторых странах (например, в Китае) VPN-приложения требуют дополнительного разрешения регулятора; распространение по регионам настраивается в App Store Connect.

---

## Чек-лист ручного тестирования VPN

Устройство: iPhone с iOS 17+, тестовая подписка от провайдера.

**Подписка**
- [ ] Вставка HTTPS-ссылки кнопкой «Вставить» и вручную; импорт Base64-подписки; импорт одиночной `vless://`.
- [ ] HTTP-ссылка, мусорный текст, Clash YAML → понятная ошибка, текущая подписка не меняется.
- [ ] Обновление подписки в режиме полёта → ошибка, серверы и выбор сохранены.
- [ ] Полная ссылка подписки нигде не отображается (только домен).
- [ ] Удаление подписки при активном VPN: подтверждение → VPN отключается → серверы исчезают, кнопка Play недоступна.

**Подключение**
- [ ] Первое подключение: экран конфиденциальности → системный запрос VPN. Отказ → понятная ошибка; повторная попытка работает.
- [ ] Статусы: Подключение → Подключено, секундомер стартует только после Connected.
- [ ] Повторные быстрые нажатия Play/Stop не ломают состояние.
- [ ] Отключение: Stop → Отключение → Отключено, секундомер `00:00:00`.
- [ ] Неверный сервер (неверный UUID / недоступный хост) → ошибка, нет ложного «Подключено».
- [ ] Каждый тип сервера: VLESS REALITY, VLESS TLS (WS/gRPC), VMess, Trojan, Shadowsocks.

**Состояние и время**
- [ ] Свернуть приложение на 5 минут → время корректное.
- [ ] Закрыть приложение из переключателя → открыть → статус и время восстановлены.
- [ ] Включение/выключение VPN из «Настройки → VPN» отражается в приложении.
- [ ] Смена сервера при активном подключении → переподключение к новому серверу.
- [ ] Выбранный сервер сохраняется после перезапуска.

**Фон и сеть**
- [ ] Заблокировать экран на 10+ минут → трафик идёт (например, загрузка в фоне), VPN остаётся подключённым.
- [ ] Переключение Wi-Fi ↔ сотовая сеть → соединение восстанавливается (статус Reasserting/Connected).
- [ ] Режим полёта вкл/выкл.
- [ ] Перезагрузка iPhone → подключение из «Настроек» без открытия приложения.

**Утечки и приватность**
- [ ] IP на ipleak.net / browserleaks.com = IP VPN-сервера.
- [ ] DNS leak test: нет DNS-серверов провайдера сети.
- [ ] IPv6 test (test-ipv6.com) в сети с IPv6: нет реального IPv6-адреса устройства.
- [ ] Console.app: в логах нет ссылок подписки, UUID, паролей, ключей.
- [ ] Память extension (Xcode → Debug Navigator при attach к `PacketTunnel`) под нагрузкой (видео, загрузки) < 50 МБ.
