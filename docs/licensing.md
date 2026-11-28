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
- **sing-box в проекте нет.** Интеграция sing-box (Libbox, `TunnelPlatformInterface.swift` по
  образцу GPL-кода sing-box-for-apple, генератор конфигурации, `build-libbox.sh`) удалена из
  репозитория в релизе 1.0.0. В `project.pbxproj` нет ссылки на `Libbox.xcframework`. В графе
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
  `THIRD_PARTY_NOTICES.md` дают три ссылки на исходники именно той версии, что в сборке:
  - тег в репозитории автора: `https://github.com/XTLS/Xray-core/tree/v26.11.9`;
  - архив модуля на `proxy.golang.org`;
  - **копия в репозитории Mono VPN** — `third_party/sources/` (см. «Доступность исходного
    кода»).
- **§3.2(b): исполняемая форма может распространяться на других условиях**, если они не
  ограничивают права получателя на исходный код. Стандартное лицензионное соглашение
  App Store этого не делает.
- **§3.3: Mono VPN может оставаться закрытым** — это Larger Work. Файлы под MPL не
  изменялись, поэтому публиковать свои изменения не нужно.

### LGPL-3.0 со static linking exception (juju/ratelimit)

`github.com/juju/ratelimit` v1.0.2 (правообладатель Canonical Ltd.) входит в сборку через
`github.com/xtls/reality`. Компилируются файлы `ratelimit.go` и `reader.go`, оба с заголовком
«Licensed under the LGPLv3 with static-linking exception». Изменений нет. Исключение из
`LICENSE` дословно:

> As a special exception to the GNU Lesser General Public License version 3 ("LGPL3"), the
> copyright holders of this Library give you permission to convey to a third party a Combined
> Work that links statically or dynamically to this Library without providing any Minimal
> Corresponding Source or Minimal Application Code as set out in 4d or providing the
> installation information set out in section 4e, provided that you comply with the other
> provisions of LGPL3 and provided that you meet, for the Application the terms and conditions
> of the license(s) which apply to the Application.
>
> Except as stated in this special exception, the provisions of LGPL3 will continue to comply
> in full to this Library. If you modify this Library, you may apply this exception to your
> version of this Library, but you are not obliged to do so. If you do not wish to do so,
> delete this exception statement from your version. This exception does not (and cannot)
> modify any license terms which apply to the Application, with which you must still comply.

**Что это значит для Mono VPN.** Combined Work — расширение PacketTunnel, в которое
библиотека слинкована статически в составе `libXray.a`, и приложение, которое его содержит.
«Application» в терминах LGPL — остальной код: Mono VPN и прочие компоненты.

**Что исключение снимает:**

| Положение LGPL-3.0 | Требование | Статус |
|---|---|---|
| §4(d)(0) | Minimal Corresponding Source (исходники Combined Work без Application, то есть и исходники самой библиотеки) и Minimal Application Code для перелинковки | **снято** |
| §4(d)(1) | Альтернатива — подключение через shared library, заменяемую пользователем | **снято** (static linking разрешён) |
| §4(e) | Installation Information для установки изменённой версии | **снято** |

Именно эти требования несовместимы с App Store: сборку там нельзя перелинковать и
переустановить. Поэтому без исключения библиотеку под чистым LGPL-3.0 распространять через
App Store было бы проблематично.

**Что остаётся** («comply with the other provisions of LGPL3»):

| Положение | Требование | Как выполнено |
|---|---|---|
| §4, вводная часть | Условия, на которых распространяется Combined Work, не должны запрещать изменение частей библиотеки для собственного использования и обратную разработку для отладки таких изменений | Стандартное EULA Apple (п. b «License Restrictions») запрещает обратную разработку, но делает исключение: «…or to the extent as may be permitted by the licensing terms governing use of any open-sourced components included with the Licensed Application». Собственного EULA, которое противоречило бы этому, у Mono VPN нет |
| §4(a) | Заметное уведомление с каждой копией, что библиотека используется и что она и её использование подпадают под LGPL | Экран «Лицензии»: первая пометка компонента — уведомление об использовании под LGPL v3 со специальным исключением |
| §4(b) | Приложить копии GNU GPL v3 и LGPL v3 | Текст LGPL v3 (из `LICENSE` библиотеки) и полный текст GNU GPL v3 (`Scripts/licenses/GPL-3.0.txt`, канонический текст FSF) — на экране и в `THIRD_PARTY_NOTICES.md` |
| §4(c) | Если программа показывает уведомления об авторских правах — включить уведомление библиотеки и ссылку на копии GPL/LGPL | Экран «Лицензии» показывает `LICENSE` (Copyright Canonical Ltd.) и тексты GPL/LGPL рядом |
| §3 | Объектный код с материалом из заголовочных файлов библиотеки — уведомление и копии лицензий | Покрывается §4(a)–(c); заголовочных файлов в Go нет |
| §2 | Изменённая версия библиотеки | Неприменимо: библиотека не изменена |
| «terms … which apply to the Application» | Остальной код распространяется по своим лицензиям | MPL-2.0, Apache-2.0, BSD, MIT соблюдаются (см. ниже) |

**Исходный код библиотеки.** Исключение снимает обязанность передавать Minimal Corresponding
Source, а она включает исходники самой библиотеки. Поэтому предоставлять их не обязательно.
Ссылки на репозиторий и архив точной версии на `proxy.golang.org` всё равно даны.

**При изменении библиотеки** исключение можно сохранить или убрать. Mono VPN библиотеку не
меняет.

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

## Доступность исходного кода

MPL-2.0 §3.2(a) требует, чтобы исходный код распространяемых файлов был доступен получателям,
пока распространяется приложение. Чтобы это не зависело от внешних хостингов, точные архивы
лежат в репозитории Mono VPN (публичный, `irklch/MonoVPN`) в `third_party/sources/`:

| Файл | Компонент | Лицензия |
|---|---|---|
| `github.com_xtls_xray-core@v1.260327.1-0.20261109052709-676eaf66f8f0.zip` | Xray-core v26.11.9 | MPL-2.0 |
| `github.com_xtls_reality@v0.0.0-20261108101329-4bb46b2afd8b.zip` | XTLS/REALITY | MPL-2.0 |
| `layeh.com_gopher-luar@v1.0.11.zip` | gopher-luar | MPL-2.0 |
| `libXray-v26.11.9.tar.gz` | libXray (commit `5a0f7d8d…`) | MIT (не обязательно, вход сборки) |

- **Архивы модулей Go** — те же zip, что использует сборка: `mirror-third-party-sources.sh`
  получает их через `go mod download` и сверяет хеш h1 с `go.sum` libXray. SHA-256 всех файлов —
  в `third_party/sources/SHA256SUMS`.
- **Ссылки в приложении** ведут на неизменяемый адрес:
  `https://github.com/irklch/MonoVPN/raw/<SHA коммита>/third_party/sources/<файл>`. SHA — у
  последнего коммита, менявшего `third_party/sources`; его берёт
  `generate-third-party-notices.sh`.
- **Другие компоненты.** Для MIT, BSD, ISC и Apache-2.0 предоставление исходников не требуется.
  Для LGPL-3.0 со static linking exception — тоже, см. выше. Для них даны ссылки на
  репозитории и архивы точных версий.

После обновления libXray / Xray-core:

```bash
MonoVPN/Scripts/mirror-third-party-sources.sh
```

Закоммитьте `third_party/sources`, затем выполните:

```bash
MonoVPN/Scripts/generate-third-party-notices.sh
```

## Риски и рекомендации

1. **Слияние в `main`.** Ссылки на копию исходников указывают на commit в ветке
   `release/1.0.0`. При слиянии обычным merge commit (не squash) он остаётся в истории `main`.
   При squash merge и удалении ветки ссылки со временем перестанут работать. Тогда нужно
   перегенерировать уведомления (или поставить тег на этот commit) до удаления ветки.
2. **Проверка собранного бинарника.** Перечень построен по исходникам и `go list`. После
   сборки архива стоит убедиться, что в `PacketTunnel` нет символов sing-box/Libbox
   (`nm PacketTunnel.appex/PacketTunnel | grep -i libbox` — пусто).
