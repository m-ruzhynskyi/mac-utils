#!/bin/bash
# Собирает "Mac Utils.app" в ./build.
#   ./build.sh             — сборка под текущую архитектуру
#   ./build.sh --universal — универсальная сборка (arm64 + x86_64, нужен Xcode)
#   ./build.sh --install   — сборка, копирование в /Applications и запуск
#   MU_RELEASE=1 ./build.sh — релизная версия и канал release (только CI, чистое дерево)
#
# Подпись: SIGN_IDENTITY, иначе сертификат «Mac Utils Signing» из связки ключей,
# иначе ad-hoc (тогда macOS может сбрасывать разрешения после пересборки).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Mac Utils"
EXECUTABLE="MacUtils"
INSTALL=0
ARCH_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --install)   INSTALL=1 ;;
        --universal) ARCH_ARGS=(--arch arm64 --arch x86_64) ;;
        *) echo "Неизвестный параметр: $arg" >&2; exit 1 ;;
    esac
done

# Версию считаем до сборки: ошибка (грязное дерево в release, неверная линия) не должна тратить время на компиляцию.
VERSION_OUT="$(./scripts/version.sh)" || exit 1
version_field() { printf '%s\n' "$VERSION_OUT" | sed -n "s/^$1=//p" | head -1; }
V_SHORT="$(version_field SHORT)"; V_BUILD="$(version_field BUILD)"; V_CHANNEL="$(version_field CHANNEL)"
V_COMMIT="$(version_field COMMIT)"; V_SINCE="$(version_field SINCE)"
[[ -n "$V_SHORT" && -n "$V_BUILD" && -n "$V_CHANNEL" ]] || { echo "version.sh вернул неполный вывод" >&2; exit 1; }

# Константы для метаданных App Intents (действия в «Командах») — scripts/appintents-metadata.sh.
INTENT_FLAGS=()
while IFS= read -r flag; do INTENT_FLAGS+=("$flag"); done < <(./scripts/appintents-metadata.sh flags)
swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} "${INTENT_FLAGS[@]}"
BIN_DIR="$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} "${INTENT_FLAGS[@]}" --show-bin-path)"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Версия — из Info.plist (X.Y.0) и тегов, см. scripts/version.sh и docs/VERSIONING.md.
# Релизный канал только при MU_RELEASE=1; dev-сборка сама ничего не ставит (Updater).
PLIST="$APP/Contents/Info.plist"
plist_set() {  # <ключ> <значение> — добавить или заменить
    /usr/libexec/PlistBuddy -c "Set :$1 $2" "$PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$PLIST"
}
plist_set CFBundleShortVersionString "$V_SHORT"
plist_set CFBundleVersion "$V_BUILD"
plist_set MUReleaseChannel "$V_CHANNEL"
plist_set MUGitCommit "$V_COMMIT"
plist_set MUCommitsSinceRelease "$V_SINCE"
echo "Версия: $V_SHORT ($V_CHANNEL, $V_COMMIT)"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Шрифты интерфейса (Manrope, JetBrains Mono — SIL OFL 1.1) с лицензиями; регистрируются при запуске (DSFonts).
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"

# Действия Mac Utils в «Командах» и фразы Siri: Contents/Resources/Metadata.appintents (до подписи).
./scripts/appintents-metadata.sh extract "$APP"

# Помощник «Сейчас играет» (грузится в системный perl — см. Helpers/NowPlaying.m).
clang -fobjc-arc -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
    -framework Foundation -framework AppKit Helpers/NowPlaying.m \
    -o "$APP/Contents/Resources/MUNowPlaying.dylib"

# Значок «Инструменты»: маленькое приложение внутри, Mac Utils копирует его в Программы.
TOOLS="$APP/Contents/Resources/Инструменты.app"
mkdir -p "$TOOLS/Contents/MacOS" "$TOOLS/Contents/Resources"
cp "$BIN_DIR/ToolsLauncher" "$TOOLS/Contents/MacOS/ToolsLauncher"
cp Resources/ToolsLauncher-Info.plist "$TOOLS/Contents/Info.plist"
cp Resources/ToolsIcon.icns "$TOOLS/Contents/Resources/ToolsIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")" "$TOOLS/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")" "$TOOLS/Contents/Info.plist"

# Постоянная подпись «Mac Utils Signing» (см. scripts/make-signing-cert.sh) — тогда
# macOS не сбрасывает разрешения после пересборки и автообновления.
IDENTITY="${SIGN_IDENTITY:-}"
EXPLICIT_IDENTITY=0
[[ -n "$IDENTITY" ]] && EXPLICIT_IDENTITY=1
if [[ -z "$IDENTITY" ]] && security find-certificate -c "Mac Utils Signing" >/dev/null 2>&1; then
    IDENTITY="Mac Utils Signing"
fi
# Вложенное приложение подписывается первым, затем внешнее.
if [[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/MUNowPlaying.dylib" \
    && codesign --force --sign "$IDENTITY" "$TOOLS" && codesign --force --sign "$IDENTITY" "$APP"; then
    echo "Подписано: $IDENTITY"
else
    # SIGN_IDENTITY задан явно (релиз) — молчаливый ad-hoc оставил бы пользователей без автообновления.
    if (( EXPLICIT_IDENTITY )); then
        echo "Не удалось подписать «$IDENTITY» (SIGN_IDENTITY задан явно), ad-hoc не подставляю" >&2
        exit 1
    fi
    [[ -n "$IDENTITY" ]] && echo "Не удалось подписать «$IDENTITY», подписываю ad-hoc" >&2
    codesign --force --sign - "$APP/Contents/Resources/MUNowPlaying.dylib"
    codesign --force --sign - "$TOOLS"
    codesign --force --sign - "$APP"
fi
echo "Готово: $APP"

if (( INSTALL )); then
    pkill -x "$EXECUTABLE" 2>/dev/null || true
    # Ждём, пока старый процесс завершится: иначе `open` падает с ошибкой -600.
    for _ in {1..50}; do pgrep -x "$EXECUTABLE" >/dev/null || break; sleep 0.1; done
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/"
    touch "/Applications/$APP_NAME.app"  # обновить иконку в Finder
    open "/Applications/$APP_NAME.app"
    echo "Установлено в /Applications"
fi
