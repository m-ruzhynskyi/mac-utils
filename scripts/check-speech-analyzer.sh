#!/bin/bash
# Страж COPILOT-41: приложение собрано на SDK macOS 26+ и в нём есть код SpeechAnalyzer.
# В 1.11.1 релиз собирался на macos-15 (SDK 15.5, Swift < 6.2): весь код под `#if compiler(>=6.2)` выпал,
# и подсказчик не включался («Расшифровка на устройстве … ещё не подключён»). Такая сборка здесь падает.
#   scripts/check-speech-analyzer.sh "build/Mac Utils.app"
set -euo pipefail
app="${1:?путь к .app}"
bin="$app/Contents/MacOS/MacUtils"
[[ -f "$bin" ]] || { echo "::error::Нет бинарника $bin"; exit 1; }
# SDK и минимальная macOS из LC_BUILD_VERSION.
build=$(otool -l "$bin" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{m=$2} f&&/sdk/{s=$2; print m" "s; exit}')
minos=${build% *}; sdk=${build#* }
echo "MacUtils: minos $minos, sdk $sdk"
[[ "${sdk%%.*}" -ge 26 ]] || { echo "::error::Собрано на SDK $sdk — нужен SDK macOS 26+ (иначе SpeechAnalyzer выпадает из сборки)"; exit 1; }
[[ "$minos" == "14.0" ]] || { echo "::error::minos $minos, ожидалось 14.0"; exit 1; }
# Ссылки на классы Speech: SpeechTranscriber (SpeechAnalyzer) должен быть в бинарнике.
count=$(nm -u "$bin" | grep -c 'SpeechTranscriber' || true)
echo "MacUtils: символов SpeechTranscriber — $count"
[[ "$count" -gt 0 ]] || { echo "::error::В бинарнике нет SpeechTranscriber — расшифровка подсказчика вырезана сборкой"; exit 1; }
