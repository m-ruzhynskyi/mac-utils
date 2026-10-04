#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Собирает "Mac Utils.app" в ./build.
#   ./build.sh             — сборка под текущую архитектуру
#   ./build.sh --universal — универсальная сборка (arm64 + x86_64, нужен Xcode)
#   ./build.sh --install   — сборка, копирование в /Applications и запуск
#
# По умолчанию приложение подписывается ad-hoc. Чтобы macOS не сбрасывала
# разрешения после каждой пересборки, задайте свой сертификат:
#   SIGN_IDENTITY="Apple Development: Имя (TEAMID)" ./build.sh
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

codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Готово: $APP"

if (( INSTALL )); then
    pkill -x "$EXECUTABLE" 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/"
    open "/Applications/$APP_NAME.app"
    echo "Установлено в /Applications"
fi
