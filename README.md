# Mono VPN

Минималистичный VPN-клиент для iOS. Пользователь вставляет ссылку подписки, выбирает сервер и нажимает Play. Собственных серверов, backend, аналитики, авторизации у приложения нет: оно подключается к серверам стороннего провайдера из подписки пользователя.

- Платформа: iOS 17.0+, iPhone, портретная ориентация.
- Стек: Swift, SwiftUI, MVVM, Swift Concurrency, NetworkExtension (`NETunnelProviderManager` + `NEPacketTunnelProvider`), Keychain, App Groups.
- VPN Core: [sing-box](https://github.com/SagerNet/sing-box) **v1.14.4** (Libbox, собирается локально в `Libbox.xcframework`).
- Сторонних Swift-зависимостей нет.

> **Статус.** Код собирается для устройства (arm64, без подписи) и симулятора, unit-тесты проходят, конфигурации sing-box проходят `sing-box check`. **Реальное VPN-подключение не проверено:** для этого нужны платный Apple Developer аккаунт и физический iPhone (см. «Что проверить на iPhone»). До такой проверки VPN нельзя считать работающим.

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
9. [Лицензионные требования](#лицензионные-требования)
10. [Известные ограничения](#известные-ограничения)
11. [Ограничения Apple для VPN-приложений](#ограничения-apple-для-vpn-приложений)
12. [Чек-лист ручного тестирования VPN](#чек-лист-ручного-тестирования-vpn)

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
├── Shared/                  Код и строки для приложения и extension: AppIdentifiers, SecureStorage, Tunnel.xcstrings
├── PacketTunnel/            PacketTunnelProvider, TunnelPlatformInterface (мост Libbox ↔ NetworkExtension)
├── Config/                  Identifiers.xcconfig, Info.plist, entitlements
├── Scripts/                 build-libbox.sh
└── Tests/                   Unit-тесты (Swift Testing)
```

Папки подключены к Xcode как синхронизируемые группы (Xcode 16+): новые файлы в папке автоматически попадают в нужный target.

| Target | Тип | Папки |
|---|---|---|
| `MonoVPN` | приложение | App, Core, Models, Features, DesignSystem, Resources, Shared |
| `PacketTunnel` | Packet Tunnel Provider extension (встраивается в приложение) | PacketTunnel, Shared + Libbox.xcframework, NetworkExtension, UIKit, libresolv |
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

Команда разработчика в проекте **не указана**. Чужие Team ID, сертификаты и команды не используются.

Все идентификаторы — в одном месте: `MonoVPN/Config/Identifiers.xcconfig`.

| Параметр | Значение |
|---|---|
| Display Name | Mono VPN |
| App Bundle ID | `com.irklch.monovpn` |
| Packet Tunnel Bundle ID | `com.irklch.monovpn.PacketTunnel` |
| App Group | `group.com.irklch.monovpn` |
| Keychain Sharing group | `$(AppIdentifierPrefix)com.irklch.monovpn.shared` |
| Signing | Automatic, `DEVELOPMENT_TEAM` пуст |

Info.plist обоих targets получают значения из xcconfig, Swift-код читает их из Info.plist (`AppIdentifiers`). Если идентификатор занят — поменяйте его только в xcconfig.

### Entitlements

`MonoVPN/Config/MonoVPN.entitlements` и `MonoVPN/Config/PacketTunnel.entitlements` (одинаковые):

```xml
<key>com.apple.developer.networking.networkextension</key>
<array><string>packet-tunnel-provider</string></array>
<key>com.apple.security.application-groups</key>
<array><string>$(MONO_APP_GROUP)</string></array>
<key>keychain-access-groups</key>
<array><string>$(AppIdentifierPrefix)$(MONO_BUNDLE_ID).shared</string></array>
```

### После активации личного Apple Developer Program

1. Xcode → Settings → Accounts: добавьте **свой** Apple ID и выберите **личную** команду (не команду работодателя).
2. Укажите Team ID: либо `DEVELOPMENT_TEAM = XXXXXXXXXX` в `Identifiers.xcconfig`, либо в Xcode → target → Signing & Capabilities для **обоих** targets (`MonoVPN` и `PacketTunnel`).
3. При Automatic Signing Xcode сам зарегистрирует App ID для обоих Bundle ID, App Group и Keychain Sharing group в вашей команде. Проверьте на вкладке Signing & Capabilities обоих targets, что есть:
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
   - добавьте иконку приложения 1024×1024 в `Resources/Assets.xcassets/AppIcon` — **без иконки App Store Connect отклонит сборку** (кастомная иконка не входила в MVP);
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

Запрос подписки отправляется с `User-Agent: MonoVPN/<версия>`. Строки-комментарии (`#`, `//`) и дубликаты пропускаются. Записи с неподдерживаемыми протоколами/параметрами перечисляются в разделе «Пропущено записей».

### Протоколы

| Протокол | Транспорты | Безопасность |
|---|---|---|
| **VLESS** | TCP (RAW), WebSocket (включая early data `?ed=`), gRPC, HTTP/2, HTTPUpgrade | none, TLS, **REALITY**; flow `xtls-rprx-vision` |
| **VMess** (v2rayN JSON) | те же | none, TLS |
| **Trojan** | те же | TLS (по умолчанию), REALITY |
| **Shadowsocks** (SIP002 и legacy) | TCP/UDP | `2022-blake3-*`, `aes-128/192/256-gcm`, `(x)chacha20-ietf-poly1305` |

Не поддерживается (ссылка отклоняется с понятной причиной): XHTTP/SplitHTTP, mKCP, QUIC-транспорт, TCP с HTTP-обфускацией, VLESS `encryption` ≠ `none`, flow кроме `xtls-rprx-vision`, плагины Shadowsocks, потоковые шифры Shadowsocks, Hysteria/TUIC/WireGuard и прочие схемы.

Сообщаются как «Не применено» (сервер импортируется): `allowInsecure=1` (проверка сертификата **никогда** не отключается), `spx` (spiderX REALITY), неизвестный `fp` (заменяется на `chrome`), gRPC `mode=multi`, любые неизвестные параметры.

Страна сервера не определяется и не угадывается — показываются только имя из конфигурации и протокол.

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
- Нет иконки приложения (требуется для загрузки в App Store Connect).
- Английская локализация не добавлена: структура готова (String Catalog, `knownRegions` включает `en`), достаточно добавить переводы в `Localizable.xcstrings` и `Tunnel.xcstrings`.
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
