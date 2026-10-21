#!/bin/bash
# Метаданные App Intents (действия Mac Utils в «Командах», фразы Siri и Spotlight) для сборки SwiftPM.
# Xcode делает это сам: компилятор отдаёт константы типов App Intents (-emit-const-values), а
# appintentsmetadataprocessor из toolchain собирает из них Contents/Resources/Metadata.appintents.
#   scripts/appintents-metadata.sh flags               — флаги для `swift build` (по одному в строке)
#   scripts/appintents-metadata.sh extract <app>       — собрать Metadata.appintents в <app> и проверить
# Без метаданных «Команды» действий не увидят — поэтому любая ошибка здесь останавливает сборку.
set -euo pipefail
cd "$(dirname "$0")/.."

MODULE="MacUtils"
PROTOCOLS=".build/appintents-protocols.json"

toolchain() { dirname "$(dirname "$(dirname "$(xcrun --find swift)")")"; }

# Протоколы, чьи константы нужны процессору, — из toolchain (так делает Xcode); у старого toolchain файла нет — список
# по документации AppIntents.
write_protocols() {
    mkdir -p .build
    local listed
    listed="$(toolchain)/usr/share/swift/SwiftConstantValues/AppIntents.json"
    local fresh="$PROTOCOLS.new"
    if [[ -f "$listed" ]]; then
        plutil -extract constValueProtocols json -o "$fresh" "$listed"
    else
        printf '%s' '["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","IntentValueQuery","Resolver","_IntentValueRepresentable","_AssistantIntentsProvider","_GenerativeFunctionExtractable"]' > "$fresh"
    fi
    # Тот же список — тот же файл: иначе меняется время, и swift build пересобирает всё заново.
    if cmp -s "$fresh" "$PROTOCOLS"; then rm "$fresh"; else mv "$fresh" "$PROTOCOLS"; fi
}

case "${1:-}" in
    flags)
        write_protocols
        printf '%s\n' -Xswiftc -emit-const-values \
            -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$PWD/$PROTOCOLS"
        ;;
    extract)
        APP="${2:?путь к .app}"
        WORK="$(mktemp -d)"
        trap 'rm -rf "$WORK"' EXIT
        # Константы модуля из последней сборки: каталог самого свежего файла (универсальная сборка — arm64; метаданные
        # от архитектуры не зависят). Пересборки не было — файлы прошлой сборки этих же исходников.
        NEWEST="$(find .build -name '*.swiftconstvalues' -path "*$MODULE*" ! -path '*Tests*' ! -path '*ToolsLauncher*' \
            \( -ipath '*release*' \) -print0 | xargs -0 ls -t 2>/dev/null | grep -m1 '/arm64/' || true)"
        [[ -n "$NEWEST" ]] || NEWEST="$(find .build -name '*.swiftconstvalues' -path "*$MODULE*" ! -path '*Tests*' \
            ! -path '*ToolsLauncher*' -ipath '*release*' -print0 | xargs -0 ls -t 2>/dev/null | head -1 || true)"
        [[ -n "$NEWEST" ]] || { echo "Нет констант App Intents (*.swiftconstvalues): соберите с флагами «$0 flags»" >&2; exit 1; }
        find "$(dirname "$NEWEST")" -maxdepth 1 -name '*.swiftconstvalues' | sed "s#^#$PWD/#;s#^$PWD/$PWD/#$PWD/#" > "$WORK/consts.txt"
        find "$PWD/Sources/$MODULE" -name '*.swift' > "$WORK/sources.txt"
        ARCH="$(basename "$(dirname "$NEWEST")")"; [[ "$ARCH" == arm64 || "$ARCH" == x86_64 ]] || ARCH="$(uname -m)"
        XCODE_BUILD="$(xcodebuild -version | awk '/Build version/ { print $3 }')"
        BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
        DEPLOYMENT="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
        rm -rf "$APP/Contents/Resources/Metadata.appintents"
        xcrun appintentsmetadataprocessor \
            --output "$APP/Contents/Resources" \
            --toolchain-dir "$(toolchain)" \
            --module-name "$MODULE" \
            --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
            --xcode-version "$XCODE_BUILD" \
            --platform-family macOS \
            --deployment-target "$DEPLOYMENT" \
            --target-triple "$ARCH-apple-macos$DEPLOYMENT" \
            --bundle-identifier "$BUNDLE_ID" \
            --binary-file "$APP/Contents/MacOS/$MODULE" \
            --source-file-list "$WORK/sources.txt" \
            --swift-const-vals-list "$WORK/consts.txt" \
            --quiet-warnings > "$WORK/log.txt" 2>&1 || { cat "$WORK/log.txt" >&2; exit 1; }
        DATA="$APP/Contents/Resources/Metadata.appintents/extract.actionsdata"
        [[ -f "$DATA" ]] || { cat "$WORK/log.txt" >&2; echo "Metadata.appintents не создан" >&2; exit 1; }
        # JSON читается plutil (-lint его не берёт); `raw` у словаря печатает ключи по строке, у массива — число.
        COUNT="$(plutil -extract actions raw -o - "$DATA" 2>/dev/null | grep -c . || true)"
        SHORTCUTS="$(plutil -extract autoShortcuts raw -o - "$DATA" 2>/dev/null || echo 0)"
        (( COUNT > 0 )) || { echo "В Metadata.appintents нет действий" >&2; exit 1; }
        echo "App Intents: действий $COUNT, фраз Siri $SHORTCUTS"
        ;;
    *)
        echo "Использование: $0 flags | extract <app>" >&2
        exit 1
        ;;
esac
