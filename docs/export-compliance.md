# Export Compliance

Состояние на релиз 1.0.0. Опирается на документацию Apple: «Complying with Encryption
Export Regulations», `ITSAppUsesNonExemptEncryption`, App Store Connect Help «Overview of
export compliance» и «Export compliance documentation for encryption». Это технический разбор,
а не юридическое заключение. Ответственность за классификацию по EAR, как прямо пишет Apple,
несёт разработчик.

## Какое шифрование использует приложение

| Где | Что | Чьей реализацией |
|---|---|---|
| Загрузка подписки | HTTPS (`URLSession`) | ОС Apple |
| Keychain, защита файлов | Data Protection | ОС Apple |
| VPN-туннель (расширение PacketTunnel) | TLS 1.2/1.3 и REALITY (X25519, гибрид X25519MLKEM768, AES-GCM, ChaCha20-Poly1305), uTLS, VLESS, VMess (AES-128-GCM / ChaCha20-Poly1305), Trojan, Shadowsocks AEAD и 2022 (AES-GCM, ChaCha20-Poly1305, BLAKE3), QUIC / Hysteria2, DoH | **Xray-core** (Go `crypto`, golang.org/x/crypto, uTLS, REALITY, quic-go) |

Шифрование в туннеле — основная функция приложения (защита передаваемых данных). Оно
реализовано не средствами iOS, а собственным кодом Xray-core, слинкованным в приложение.

Алгоритмы стандартные (AES, ChaCha20-Poly1305, X25519, ML-KEM, SHA-2, BLAKE3).
Протоколы VLESS, VMess, Shadowsocks и REALITY не утверждены организациями по стандартизации,
но опубликованы: открытый исходный код и спецификации. Определение «non-standard
cryptography» в EAR Part 772 относится к проприетарной или неопубликованной криптографии,
поэтому, по нашей оценке, это не «proprietary/non-standard encryption». Эту оценку стоит
подтвердить у юриста.

## Info.plist

В `MonoVPN/Config/App-Info.plist` задано:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<true/>
```

Обоснование по документации Apple: `NO` ставится, только если приложение, включая
слинкованные библиотеки, не использует шифрование или использует только шифрование,
освобождённое от требований к документации, — типично это шифрование ОС, например HTTPS
через `URLSession`. Mono VPN использует собственную криптографию Xray-core для VPN, поэтому —
`YES`.

`ITSEncryptionExportComplianceCode` пока не задан. Apple выдаёт этот код после проверки
загруженной документации. Документация нужна, только если приложение будет доступно во
Франции (см. ниже). Без кода App Store Connect при каждой загрузке сборки задаёт вопросы о
шифровании — ответы приведены ниже.

## Ответы в App Store Connect

1. **What type of encryption algorithms does your app implement?** — *Standard encryption
   algorithms instead of, or in addition to, using or accessing the encryption within Apple's
   operating system.*
2. **Is your app going to be available on the App Store in France?**
   - **Нет:** для стандартных алгоритмов документация в App Store Connect не требуется
     (таблица Apple «Export compliance documentation for encryption»).
   - **Да:** нужно загрузить French encryption declaration (ANSSI). Это декларация для
     средств защищённой связи, к ним относятся VPN. После одобрения Apple выдаст код —
     добавить его в `App-Info.plist` как `ITSEncryptionExportComplianceCode`.
3. Если появится вопрос об освобождениях по Category 5, Part 2 EAR — **нет**: шифрование
   используется не только для аутентификации и не только средствами ОС.

## Классификация по EAR (США)

- Приложение публикуется через серверы Apple в США, поэтому на него распространяются правила
  экспорта США, независимо от страны разработчика.
- Ожидаемая классификация — **5D992.c** (mass market, License Exception ENC §740.17(b)(1)).
  Признаки: общедоступно через розничный канал (App Store), криптографию пользователь не
  меняет, установка без поддержки поставщика.
- CCATS для стандартных алгоритмов не требуется: Apple требует CCATS только для
  проприетарных алгоритмов.
- Ежегодный self-classification report: Apple пишет, что он может понадобиться для
  освобождённого шифрования. Для массового ПО по §740.17(b)(1) BIS с 2021 года в общем случае
  этот отчёт не требует (кроме компонентов, наборов микросхем и т. п.). Подтвердите у юриста.
- Страны под эмбарго (E:1/E:2) App Store и так исключает.

## Ввоз (import) и регионы

- **Китай (материковый):** VPN-приложения требуют лицензии; исключить регион в App Store
  Connect → Pricing and Availability.
- **Россия:** Apple удаляет VPN-приложения по требованиям регулятора — решение о доступности
  принимает владелец.
- **Франция:** см. выше (ANSSI).
- Другие страны с ограничениями на VPN или криптографию — проверить перед включением.

## Чек-лист

- [ ] Решить по Франции. Если «да» — подать декларацию ANSSI через App Store Connect, получить
      код и добавить `ITSEncryptionExportComplianceCode`.
- [ ] При загрузке сборки ответить на вопросы, как указано выше.
- [ ] Исключить China mainland, решить по России.
- [ ] Подтвердить у юриста классификацию 5D992.c и отсутствие обязанности подавать
      self-classification report.
