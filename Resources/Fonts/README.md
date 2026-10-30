# Шрифты интерфейса и «Документа»

| Файл | Шрифт | Источник | Лицензия |
|---|---|---|---|
| `Manrope[wght].ttf` | Manrope, переменный (200–800) | github.com/google/fonts — `ofl/manrope` | SIL Open Font License 1.1 — `OFL-Manrope.txt` |
| `JetBrainsMono[wght].ttf` | JetBrains Mono, переменный (100–800) | github.com/google/fonts — `ofl/jetbrainsmono` | SIL Open Font License 1.1 — `OFL-JetBrainsMono.txt` |
| `Carlito-*.ttf` (4 начертания) | Carlito — метрически совместим с Calibri | github.com/google/fonts — `ofl/carlito` | SIL Open Font License 1.1 — `OFL-Carlito.txt` |
| `Caladea-*.ttf` (4 начертания) | Caladea 1.002 — метрически совместим с Cambria (латиница) | ChromeOS `crosextrafonts-20130214` (поздние версии с GitHub по ширинам с Cambria уже не совпадают) | Apache License 2.0 — `LICENSE-Caladea-Apache-2.0.txt` |

Файлы не изменялись. `build.sh` копирует папку в `Mac Utils.app/Contents/Resources/Fonts`; при запуске шрифты
регистрируются только для процесса (`DSFonts.registerAll`, `CTFontManagerRegisterFontsForURL`, `.process`).
Если регистрация не удалась, интерфейс использует системный шрифт.
Carlito и Caladea — запасные шрифты «Документа», когда на Mac нет Microsoft Word: регистрируются для процесса
только при открытии документа с Calibri/Cambria (`WordFonts`). Есть Word — берутся шрифты из его бандла, эти не нужны.
