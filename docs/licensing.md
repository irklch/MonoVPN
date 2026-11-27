# Лицензии сторонних компонентов и распространение через App Store

Состояние на релиз 1.0.0 (build 1): Xray-core v26.11.9 через libXray v26.11.9, Go 1.27.3.
Документ описывает, какие лицензии действуют, какие обязательства они накладывают при
распространении приложения через App Store и как эти обязательства выполнены. Это технический
разбор, а не юридическое заключение: окончательную оценку стоит получить у юриста.

## Что входит в сборку

- **Swift-код Mono VPN** — собственный код, сторонних Swift-пакетов нет. Используются только
  системные фреймворки Apple (SwiftUI, NetworkExtension, WidgetKit, AppIntents, Security).
- **libXray** (`Frameworks/LibXray.xcframework`) — статическая библиотека, собранная
  `MonoVPN/Scripts/build-libxray.sh` из libXray v26.11.9 (commit `5a0f7d8d`). Линкуется только
  в расширение PacketTunnel. Внутри — Xray-core v26.11.9 (commit `676eaf66`), его зависимости
  и рантайм Go.
- **sing-box в сборку не входит.** В `project.pbxproj` нет ссылки на `Libbox.xcframework`;
  `PacketTunnelProvider.swift` и `TunnelPlatformInterface.swift` (sing-box) обёрнуты в
  `#if !MONO_CORE_XRAY`, а флаг задан в `Identifiers.xcconfig` для всех конфигураций. В графе
  Go-пакетов libXray для iOS нет ни `sagernet/*`, ни кода под GPL.

Полный перечень — 49 компонентов: 48 модулей Go и стандартная библиотека Go. Он получен из
`go list -deps` для `./cgo_bridge` с `GOOS=ios`, то есть это именно пакеты, которые
компилируются в библиотеку для iPhone. Перечень с полными текстами — в
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) и в приложении: «Подписка → Лицензии».

| Лицензия | Компоненты |
|---|---|
| MPL-2.0 | Xray-core, XTLS/REALITY, layeh.com/gopher-luar |
| LGPL-3.0 со static linking exception | github.com/juju/ratelimit |
| Apache-2.0 | grpc-go, go-genproto, go-yaml v2, pires/go-proxyproto, jackpal/go-nat-pmp, libp2p/go-nat; часть файлов pelletier/go-toml и klauspost/compress |
| BSD-3-Clause / BSD-2-Clause | Go, golang.org/x/*, protobuf, uTLS, miekg/dns, google/uuid, go4.org/netipx, metacubex/*, gorilla/websocket, huin/goupnp и др. |
| MIT | libXray, quic-go (apernet), pion/*, wireguard-go, gopher-lua, blake3, go-brrr, qpack и др. |

Внутри некоторых модулей есть файлы под другой лицензией или с другим правообладателем
(например, `proxy/wireguard/netstack.go` в Xray-core — MIT, WireGuard LLC; `internal/hmac` в
pion — BSD-3-Clause, The Go Authors). Генератор находит их по SPDX-заголовкам компилируемых
файлов и указывает в уведомлениях отдельно.

## Обязательства и как они выполнены

### MPL-2.0 (Xray-core, REALITY, gopher-luar)

- **§3.2(a): сообщить, как получить исходный код.** Экран «Лицензии» и
  `THIRD_PARTY_NOTICES.md` дают ссылку на тег и архив исходников именно той версии, что
  в сборке: `https://github.com/XTLS/Xray-core/tree/v26.11.9` и архив модуля с
  `proxy.golang.org`.
- **§3.2(b): исполняемая форма может распространяться на других условиях**, если они не
  ограничивают права получателя на исходный код. Стандартное лицензионное соглашение
  App Store этого не делает.
- **§3.3: Mono VPN может оставаться закрытым** — это Larger Work. Файлы под MPL не
  изменялись, поэтому публиковать свои изменения не нужно.

### LGPL-3.0 со static linking exception (juju/ratelimit)

- **Исключение снимает §4(d) и §4(e)**: не нужно давать Minimal Corresponding Source или
  возможность перелинковки, не нужны Installation Information. Именно эти требования обычно
  несовместимы с App Store.
- **Остаются обязательства:**
  - §4(a) — заметное уведомление об использовании библиотеки под LGPL;
  - §4(b) — тексты GNU GPL v3 и LGPL v3;
  - §4(c) — уведомление об авторских правах библиотеки, если приложение показывает такие уведомления.
- **Как выполнены:** на экране «Лицензии» есть компонент, LGPL с исключением и полный текст
  GPL v3 (`MonoVPN/Scripts/licenses/GPL-3.0.txt`, канонический текст FSF).
- **Условие LGPL §4** — разрешить изменение для собственного использования и обратную
  разработку для отладки таких изменений. Стандартное EULA Apple (п. «License Restrictions»)
  прямо делает исключение для условий лицензий входящих в приложение компонентов с открытым
  кодом.

### Apache-2.0

- **§4(a):** приложен текст лицензии.
- **§4(d):** приложено содержимое файлов `NOTICE` (grpc-go `NOTICE.txt`, go-yaml `NOTICE`).
- Изменений нет, поэтому §4(b) не применяется.

### MIT, BSD, ISC

- **Требование:** воспроизвести уведомление об авторских правах и текст лицензии в
  документации или материалах, сопровождающих бинарный дистрибутив.
- **Как выполнено:** тексты из исходников приложены без изменений.
- **BSD-3 (запрет использовать имена авторов для продвижения):** соблюдается.

### Go `PATENTS`

Дополнительное патентное разрешение Google, обязательств не накладывает. Включено для полноты.

## Где пользователь видит уведомления

- **В приложении:** «Подписка → Лицензии». Экран `Features/Legal/LicensesView.swift` читает
  `Resources/ThirdPartyNotices.json`. Для каждого компонента показаны версия, лицензия,
  ссылки на исходный код и архив версии, пометки о файлах под другой лицензией и полные
  тексты по кнопке «Показать текст лицензии».
- **В репозитории:** [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

## Обновление при смене версий

После любого изменения версий в `build-libxray.sh`:

```bash
MonoVPN/Scripts/generate-third-party-notices.sh
```

Скрипт берёт закреплённые версии из `build-libxray.sh`, сверяет commit libXray, строит граф
пакетов для iOS и перезаписывает `ThirdPartyNotices.json` и `THIRD_PARTY_NOTICES.md`. libXray
при этом не собирается. Тест `LegalNoticesTests` проверяет, что уведомления входят в бандл,
есть ссылка на исходники Xray-core и текст GPL для LGPL-компонента.

## Риски и рекомендации

1. **Доступность исходников по MPL.** Ссылки ведут на GitHub и `proxy.golang.org`. MPL
   требует, чтобы исходный код был доступен, пока распространяется исполняемая форма.
   Надёжнее держать собственную копию: форк XTLS/Xray-core и XTLS/libXray с тегами или
   архив исходников на сайте Mono VPN.
2. **Остатки sing-box в репозитории.** `TunnelPlatformInterface.swift` сделан по образцу
   GPL-кода sing-box-for-apple. В сборку он не попадает, но если репозиторий публичный, в нём
   лежит производный от GPL файл без лицензии. Рекомендуется удалить sing-box-файлы
   (`PacketTunnel/PacketTunnelProvider.swift`, `PacketTunnel/TunnelPlatformInterface.swift`,
   `Scripts/build-libbox.sh`, `Core/VPN/VPNConfigurationBuilder.swift`) отдельным изменением.
3. **Проверка собранного бинарника.** Перечень построен по исходникам и `go list`. После
   сборки архива стоит убедиться, что в `PacketTunnel` нет символов sing-box/Libbox
   (`nm PacketTunnel.appex/PacketTunnel | grep -i libbox` — пусто).
