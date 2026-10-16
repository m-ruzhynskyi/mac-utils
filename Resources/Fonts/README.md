# Шрифты интерфейса

| Файл | Шрифт | Источник | Лицензия |
|---|---|---|---|
| `Manrope[wght].ttf` | Manrope, переменный (200–800) | github.com/google/fonts — `ofl/manrope` | SIL Open Font License 1.1 — `OFL-Manrope.txt` |
| `JetBrainsMono[wght].ttf` | JetBrains Mono, переменный (100–800) | github.com/google/fonts — `ofl/jetbrainsmono` | SIL Open Font License 1.1 — `OFL-JetBrainsMono.txt` |

Файлы не изменялись. `build.sh` копирует папку в `Mac Utils.app/Contents/Resources/Fonts`; при запуске шрифты
регистрируются только для процесса (`DSFonts.registerAll`, `CTFontManagerRegisterFontsForURL`, `.process`).
Если регистрация не удалась, интерфейс использует системный шрифт.
