#!/bin/bash
# Считает версию сборки по docs/VERSIONING.md и печатает строки KEY=VALUE:
#   SHORT=1.4.3  BUILD=1004003  CHANNEL=release|dev  COMMIT=abc1234[-dirty]|unknown  SINCE=12|0|?
#   ./scripts/version.sh               — dev: наибольший тег vX.Y.* линии из Info.plist (или X.Y.0)
#   MU_RELEASE=1 ./scripts/version.sh  — release: наибольший тег линии + 1 (или X.Y.0), только на чистом дереве
# Ошибка — ненулевой код выхода и сообщение в stderr.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "version.sh: $*" >&2; exit 1; }

NUM='(0|[1-9][0-9]*)'
PLIST="Resources/Info.plist"
[[ -f "$PLIST" ]] || die "нет $PLIST"
FILE_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST" 2>/dev/null)" \
    || die "в $PLIST нет CFBundleShortVersionString"
[[ "$FILE_VERSION" =~ ^${NUM}\.${NUM}\.0$ ]] || die "в $PLIST версия «$FILE_VERSION», нужен вид X.Y.0 (PATCH считает CI)"
MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
(( ${#MAJOR} <= 4 )) || die "MAJOR слишком велик: $MAJOR"
(( MINOR <= 999 )) || die "MINOR $MINOR > 999"
BASE="$MAJOR.$MINOR"

RELEASE=0
[[ "${MU_RELEASE:-}" == "1" ]] && RELEASE=1

format() {  # <PATCH> <CHANNEL> <COMMIT> <SINCE>
    printf 'SHORT=%s.%s\nBUILD=%s\nCHANNEL=%s\nCOMMIT=%s\nSINCE=%s\n' \
        "$BASE" "$1" "$(( MAJOR * 1000000 + MINOR * 1000 + $1 ))" "$2" "$3" "$4"
}

# Без git (архив исходников): версия линии, dev.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    (( RELEASE == 0 )) || die "MU_RELEASE=1 требует git-репозиторий"
    format 0 dev unknown '?'
    exit 0
fi

# Только строгие теги vX.Y.Z (без -beta, windows-*, v1.4 и т.п.).
STRICT_TAGS="$(git tag -l 'v*' | grep -E "^v${NUM}\.${NUM}\.${NUM}\$" || true)"
LINE_TAGS="$(printf '%s\n' "$STRICT_TAGS" | grep -E "^v${BASE//./\\.}\.[0-9]+\$" || true)"
LAST_PATCH=""
if [[ -n "$LINE_TAGS" ]]; then
    LAST_PATCH="$(printf '%s\n' "$LINE_TAGS" | sed 's/^v[0-9]*\.[0-9]*\.//' | sort -n | tail -1)"
fi

COMMIT="$(git rev-parse --short HEAD 2>/dev/null)" || COMMIT="unknown"

if (( RELEASE )); then
    [[ -z "$(git status --porcelain)" ]] || die "MU_RELEASE=1 на грязном дереве: закоммитьте или уберите правки"
    # Номер линии не может быть ниже уже выпущенной: клиенты берут самый свежий релиз.
    if [[ -n "$STRICT_TAGS" ]]; then
        TOP="$(printf '%s\n' "$STRICT_TAGS" | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
        TOP_MAJOR="${TOP%%.*}"; REST="${TOP#*.}"; TOP_MINOR="${REST%%.*}"
        if (( MAJOR < TOP_MAJOR || (MAJOR == TOP_MAJOR && MINOR < TOP_MINOR) )); then
            die "линия $BASE ниже уже выпущенной $TOP_MAJOR.$TOP_MINOR (тег v$TOP)"
        fi
    fi
    # Перезапуск job на уже помеченном коммите — тот же тег.
    AT_HEAD="$(git tag --points-at HEAD | grep -E "^v${BASE//./\\.}\.[0-9]+\$" || true)"
    if [[ -n "$AT_HEAD" ]]; then
        PATCH="$(printf '%s\n' "$AT_HEAD" | sed 's/^v[0-9]*\.[0-9]*\.//' | sort -n | tail -1)"
    elif [[ -n "$LAST_PATCH" ]]; then
        PATCH=$(( LAST_PATCH + 1 ))
    else
        PATCH=0
    fi
    (( PATCH <= 999 )) || die "PATCH $PATCH > 999"
    format "$PATCH" release "$COMMIT" 0
    exit 0
fi

PATCH="${LAST_PATCH:-0}"
(( PATCH <= 999 )) || die "PATCH $PATCH > 999"
SINCE='?'
if [[ -n "$LAST_PATCH" ]]; then
    SINCE="$(git rev-list --count "v$BASE.$LAST_PATCH..HEAD" 2>/dev/null)" || SINCE='?'
fi
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || COMMIT="$COMMIT-dirty"
format "$PATCH" dev "$COMMIT" "$SINCE"
