#!/bin/bash
# Страж COPILOT-41: в приложении есть код SpeechAnalyzer (собрано на SDK macOS 26+).
# В 1.11.1 релиз собирался на macos-15 (SDK 15.5, Swift < 6.2): весь код под `#if compiler(>=6.2)` выпал,
# и подсказчик не включался («Расшифровка на устройстве … ещё не подключён»). Такая сборка здесь падает.
#   scripts/check-speech-analyzer.sh "build/Mac Utils.app"
set -euo pipefail
app="${1:?путь к .app}"
bin="$app/Contents/MacOS/MacUtils"
[[ -f "$bin" ]] || { echo "::error::Нет бинарника $bin"; exit 1; }
# minos и sdk из LC_BUILD_VERSION. sdk — только для лога: SwiftPM пишет туда то, что ему передали (локально на SDK 27.2 бывает
# «14.0»), поэтому SDK проверяет шаг Toolchain в CI (`xcrun --show-sdk-version` ≥ 26), а здесь — сами символы.
build=$(otool -l "$bin" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{m=$2} f&&/sdk/{s=$2; print m" "s; exit}')
minos=${build% *}; sdk=${build#* }
echo "MacUtils: minos $minos, sdk $sdk"
[[ "$minos" == "14.0" ]] || { echo "::error::minos $minos, ожидалось 14.0"; exit 1; }
# Ссылки на Speech.SpeechTranscriber (SpeechAnalyzer). Имя в символах Swift сжато («6Speech0A11Transcriber»),
# поэтому сначала swift-demangle: без него grep не нашёл бы и в правильной сборке.
count=$(nm -u "$bin" | xcrun swift-demangle --simplified | grep -c 'SpeechTranscriber' || true)
echo "MacUtils: ссылок на SpeechTranscriber — $count"
[[ "$count" -gt 0 ]] || { echo "::error::В бинарнике нет SpeechTranscriber — расшифровка подсказчика вырезана сборкой (SDK < 26)"; exit 1; }
