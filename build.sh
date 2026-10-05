#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Собирает "Mac Utils.app" в ./build.
#   ./build.sh             — сборка под текущую архитектуру
#   ./build.sh --universal — универсальная сборка (arm64 + x86_64, нужен Xcode)
#   ./build.sh --install   — сборка, копирование в /Applications и запуск
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

swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Локальная сборка: версия = <major.minor из Info.plist>.<число коммитов>.
# В CI версию уже проставил workflow (BASE.RUN_NUMBER) — там не трогаем.
if [[ -z "${GITHUB_ACTIONS:-}" ]] && BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null)"; then
    PLIST="$APP/Contents/Info.plist"
    BASE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST" | cut -d. -f1,2)"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BASE.$BUILD_NUMBER" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
    echo "Версия: $BASE.$BUILD_NUMBER"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Постоянная подпись «Mac Utils Signing» (см. scripts/make-signing-cert.sh) — тогда
# macOS не сбрасывает разрешения после пересборки и автообновления.
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-certificate -c "Mac Utils Signing" >/dev/null 2>&1; then
    IDENTITY="Mac Utils Signing"
fi
if [[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" "$APP"; then
    echo "Подписано: $IDENTITY"
else
    [[ -n "$IDENTITY" ]] && echo "Не удалось подписать «$IDENTITY», подписываю ad-hoc" >&2
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
