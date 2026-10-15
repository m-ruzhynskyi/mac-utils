# Mac Utils

## Версии — см. docs/VERSIONING.md
- Номер версии руками не ставить: PATCH и CFBundleVersion считает build.sh/CI, теги v* создаёт только CI при merge в main.
- Новая линия = только `X.Y.0` в Resources/Info.plist + запись "X.Y" в Changelog.releases (UI/WhatsNew.swift) в одном PR.
- Версии и теги Mac — строго `v<цифры>.<цифры>.<цифры>`; никаких суффиксов вне pre-release; теги Windows не начинаются с `v`.
- Протокол share меняется только добавочно; бамп mu-share-N — сначала relay принимает оба токена, потом клиенты.
- В README и коде не писать конкретные номера версий.
