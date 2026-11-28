# Исходный код сторонних компонентов Mono VPN

Точные исходники компонентов, которые входят в расширение PacketTunnel Mono VPN 1.0.0.
Хранятся здесь, чтобы исходный код оставался доступным, пока распространяется приложение
(MPL-2.0 §3.2), независимо от внешних хостингов. Компоненты не изменены.
Файлы создаёт `MonoVPN/Scripts/mirror-third-party-sources.sh`.

| Файл | Компонент | Версия | Лицензия | Хеш go.sum (h1) |
|---|---|---|---|---|
| `github.com_xtls_xray-core@v1.260327.1-0.20261109052709-676eaf66f8f0.zip` | github.com/xtls/xray-core | v1.260327.1-0.20261109052709-676eaf66f8f0 | MPL-2.0 | `h1:p2uoadP+ulClbJ9dn+QioF2SfBqRly6VoKJosHqwcRo=` |
| `github.com_xtls_reality@v0.0.0-20261108101329-4bb46b2afd8b.zip` | github.com/xtls/reality | v0.0.0-20261108101329-4bb46b2afd8b | MPL-2.0 | `h1:fAn11r21QiUY2oAGwENWb5ummjhWwMcs2WzkbjDMh+k=` |
| `layeh.com_gopher-luar@v1.0.11.zip` | layeh.com/gopher-luar | v1.0.11 | MPL-2.0 | `h1:8zJudpKI6HWkoh9eyyNFaTM79PY6CAPcIr6X/KTiliw=` |
| `libXray-v26.11.9.tar.gz` | github.com/XTLS/libXray | v26.11.9 (commit `5a0f7d8d1c28b34afb5727b04b26a10f6dbac7e3`) | MIT | — |

Xray-core v26.11.9 в Go называется псевдоверсией модуля, которую указывает go.mod libXray;
она соответствует тегу v26.11.9 (commit `676eaf66f8f05d4d558ee7a74b4736623d3feeb9`).

## Проверка

SHA-256 всех файлов — в `SHA256SUMS`:

```bash
cd third_party/sources && shasum -a 256 -c SHA256SUMS
```

Архивы модулей совпадают с теми, что выдаёт Go module proxy (`https://proxy.golang.org/<модуль>/@v/<версия>.zip`),
и проверяются хешем h1 из `go.sum` libXray v26.11.9.

Остальные компоненты (MIT, BSD, Apache-2.0, LGPL-3.0 со static linking exception)
не требуют предоставления исходного кода; ссылки на их исходники — в
[THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md).
