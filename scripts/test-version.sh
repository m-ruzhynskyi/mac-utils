#!/bin/bash
# Проверяет scripts/version.sh во временных git-репозиториях (политика — docs/VERSIONING.md).
#   ./scripts/test-version.sh
# Работает без сети и не трогает настоящий репозиторий: версионный скрипт копируется в temp-репо вместе с Info.plist.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SCRIPT="${VERSION_SH:-$ROOT/scripts/version.sh}"
[[ -f "$SCRIPT" ]] || { echo "Нет $SCRIPT" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Чтобы git во временных папках никогда не поднялся к настоящему репозиторию.
export GIT_CEILING_DIRECTORIES="$WORK"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  ПРОВАЛ [$CASE]: $*" >&2; }

# new_repo <MAJOR.MINOR.PATCH в Info.plist> — пустое репо с одним коммитом (скрипт и Info.plist внутри).
new_repo() {
    local dir
    dir="$(mktemp -d "$WORK/repo.XXXXXX")"
    mkdir -p "$dir/scripts" "$dir/Resources"
    cp "$SCRIPT" "$dir/scripts/version.sh"
    chmod +x "$dir/scripts/version.sh"
    write_plist "$dir" "$1"
    echo tracked > "$dir/tracked.txt"
    git -C "$dir" init -q -b main
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "initial"
    echo "$dir"
}

write_plist() {  # <dir> <версия>
    cat > "$1/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.test.macutils</string>
    <key>CFBundleShortVersionString</key>
    <string>$2</string>
    <key>CFBundleVersion</key>
    <string>0</string>
</dict>
</plist>
PLIST
}

commit() {  # <dir> [сообщение] — новый коммит (меняет файл)
    echo "$RANDOM$RANDOM" > "$1/f-$RANDOM$RANDOM.txt"
    git -C "$1" add -A
    git -C "$1" commit -q -m "${2:-change}"
}

OUT=""; STATUS=0
# run <dir> [release] — результат в OUT/STATUS (stdout+stderr вместе)
run() {
    local dir="$1" mode="${2:-dev}"
    if [[ "$mode" == release ]]; then
        OUT="$(cd "$dir" && MU_RELEASE=1 ./scripts/version.sh 2>&1)"; STATUS=$?
    else
        OUT="$(cd "$dir" && env -u MU_RELEASE ./scripts/version.sh 2>&1)"; STATUS=$?
    fi
}
val() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }

expect() {  # <ключ> <ожидаемое>
    local got
    got="$(val "$1")"
    [[ "$got" == "$2" ]] && ok || fail "$1: ожидалось '$2', получено '$got' (вывод: $(printf '%s' "$OUT" | tr '\n' ' '))"
}
expect_success() { [[ $STATUS -eq 0 ]] && ok || fail "ожидался успех, код $STATUS: $OUT"; }
expect_error()   { [[ $STATUS -ne 0 ]] && ok || fail "ожидалась ошибка, а скрипт завершился успешно: $OUT"; }

# ---------------------------------------------------------------------------
CASE="без тегов: dev"
d="$(new_repo 1.4.0)"; run "$d"
expect_success; expect SHORT 1.4.0; expect BUILD 1004000; expect CHANNEL dev; expect SINCE '?'

CASE="без тегов: release"
run "$d" release
expect_success; expect SHORT 1.4.0; expect BUILD 1004000; expect CHANNEL release

CASE="release: COMMIT — короткий SHA"
[[ "$(val COMMIT)" == "$(git -C "$d" rev-parse --short HEAD)" ]] && ok || fail "COMMIT=$(val COMMIT)"

# ---------------------------------------------------------------------------
# Теги: релизы Mac, чужая линия, windows-latest, beta.
CASE="смесь тегов: release и dev"
d="$(new_repo 1.4.0)"
git -C "$d" tag v1.3.100
commit "$d"; git -C "$d" tag v1.4.0
commit "$d"; git -C "$d" tag -a v1.4.1 -m "annotated"
commit "$d"; git -C "$d" tag windows-latest; git -C "$d" tag v1.4.2-beta.1; git -C "$d" tag v1.4.x; git -C "$d" tag v1.4
commit "$d"; commit "$d"
run "$d" release
expect_success; expect SHORT 1.4.2; expect BUILD 1004002; expect CHANNEL release
run "$d"
expect_success; expect SHORT 1.4.1; expect BUILD 1004001; expect CHANNEL dev

CASE="dev: SINCE считается от коммита наибольшего тега линии"
expect SINCE "$(git -C "$d" rev-list --count v1.4.1..HEAD)"

CASE="числовая, а не строковая сортировка: v1.4.10 > v1.4.9"
d="$(new_repo 1.4.0)"
for p in 0 1 2 9 10; do commit "$d"; git -C "$d" tag "v1.4.$p"; done
commit "$d"
run "$d"; expect SHORT 1.4.10
run "$d" release; expect SHORT 1.4.11

CASE="теги чужой линии не влияют на PATCH"
d="$(new_repo 1.5.0)"
git -C "$d" tag v1.4.7; commit "$d"; git -C "$d" tag v1.3.100
run "$d"; expect SHORT 1.5.0
run "$d" release; expect SHORT 1.5.0

CASE="линия 1.5 рядом с 1.4: release берёт свой PATCH"
d="$(new_repo 1.4.0)"
git -C "$d" tag v1.4.3; commit "$d"; git -C "$d" tag v1.4.4; commit "$d"
run "$d" release
expect_success; expect SHORT 1.4.5

# ---------------------------------------------------------------------------
CASE="перезапуск release на теговом коммите даёт тот же тег"
d="$(new_repo 1.4.0)"
git -C "$d" tag v1.4.0; commit "$d"; git -C "$d" tag v1.4.1
run "$d" release
expect_success; expect SHORT 1.4.1; expect BUILD 1004001
run "$d" release
expect_success; expect SHORT 1.4.1

CASE="dev на теговом коммите: SINCE=0"
run "$d"; expect SHORT 1.4.1; expect SINCE 0

CASE="перезапуск: нестрогий тег на коммите (beta) не считается релизным"
d="$(new_repo 1.4.0)"
git -C "$d" tag v1.4.0; commit "$d"; git -C "$d" tag v1.4.1-beta.1
run "$d" release
expect_success; expect SHORT 1.4.1

# ---------------------------------------------------------------------------
CASE="BASE ниже существующей линии: release — ошибка"
d="$(new_repo 1.3.0)"
git -C "$d" tag v1.3.100; commit "$d"; git -C "$d" tag v1.4.0
run "$d" release
expect_error

CASE="BASE ниже существующей линии: dev не выдаёт версию новее линии"
run "$d"
if [[ $STATUS -eq 0 ]]; then
    [[ "$(val SHORT)" == 1.3.* ]] && ok || fail "dev выдал $(val SHORT)"
else
    ok
fi

CASE="BASE выше существующих линий: release начинает с X.Y.0"
d="$(new_repo 1.5.0)"
git -C "$d" tag v1.4.9
run "$d" release
expect_success; expect SHORT 1.5.0

# ---------------------------------------------------------------------------
CASE="грязное дерево: release — ошибка"
d="$(new_repo 1.4.0)"
echo dirty >> "$d/tracked.txt"
run "$d" release
expect_error

CASE="грязное дерево: untracked-файл тоже считается грязным в release"
d="$(new_repo 1.4.0)"
echo x > "$d/untracked.txt"
run "$d" release
expect_error

CASE="грязное дерево: dev помечает COMMIT как -dirty"
d="$(new_repo 1.4.0)"
run "$d"
[[ "$(val COMMIT)" != *-dirty ]] && ok || fail "чистое дерево помечено dirty: $(val COMMIT)"
echo dirty >> "$d/tracked.txt"
git -C "$d" add -A
run "$d"
expect_success
[[ "$(val COMMIT)" == *-dirty ]] && ok || fail "грязное дерево без -dirty: $(val COMMIT)"

# ---------------------------------------------------------------------------
CASE="MINOR > 999: ошибка"
d="$(new_repo 1.1000.0)"
run "$d" release; expect_error

CASE="MINOR = 999: допустимо, BUILD по формуле"
d="$(new_repo 1.999.0)"
run "$d" release; expect_success; expect BUILD 1999000

CASE="PATCH > 999: release — ошибка"
d="$(new_repo 1.4.0)"
git -C "$d" tag v1.4.999; commit "$d"
run "$d" release; expect_error

CASE="PATCH = 999 уже выпущен: dev работает"
run "$d"; expect_success; expect SHORT 1.4.999; expect BUILD 1004999

CASE="PATCH = 998 → release выдаёт 999"
d="$(new_repo 1.4.0)"
git -C "$d" tag v1.4.998; commit "$d"
run "$d" release; expect_success; expect SHORT 1.4.999; expect BUILD 1004999

CASE="PATCH в Info.plist не 0: ошибка"
d="$(new_repo 1.4.3)"
run "$d" release; expect_error
run "$d"; expect_error

CASE="кривой Info.plist (не X.Y.0): ошибка"
d="$(new_repo 1.4)"
run "$d" release; expect_error
d="$(new_repo 1.4.0-beta)"
run "$d" release; expect_error

# ---------------------------------------------------------------------------
CASE="формула BUILD = MAJOR*1000000 + MINOR*1000 + PATCH"
for case in "1.4:1004000" "2.7:2007000" "10.0:10000000" "0.1:1000" "1.999:1999000"; do
    v="${case%%:*}"; b="${case##*:}"
    d="$(new_repo "$v.0")"
    run "$d" release
    expect_success; expect SHORT "$v.0"; expect BUILD "$b"
done
d="$(new_repo 2.7.0)"; git -C "$d" tag v2.7.12; commit "$d"
run "$d"; expect SHORT 2.7.12; expect BUILD 2007012
run "$d" release; expect_success; expect SHORT 2.7.13; expect BUILD 2007013

CASE="BUILD больше, чем у v1.3.100 (221), и растёт с версией"
d="$(new_repo 1.4.0)"; run "$d"
[[ "$(val BUILD)" -gt 221 ]] && ok || fail "BUILD=$(val BUILD)"
prev=0
for p in 0 1 2 3; do
    d="$(new_repo 1.4.0)"
    for ((q = 0; q < p; q++)); do git -C "$d" tag "v1.4.$q"; commit "$d"; done
    run "$d" release
    [[ "$(val BUILD)" -gt "$prev" ]] && ok || fail "BUILD не вырос: $(val BUILD) <= $prev"
    prev="$(val BUILD)"
done

# ---------------------------------------------------------------------------
CASE="merge-коммиты не меняют PATCH: ветка с мержами = линейная история"
lin="$(new_repo 1.4.0)"
git -C "$lin" tag v1.4.0; commit "$lin"; git -C "$lin" tag v1.4.1
commit "$lin"; commit "$lin"; commit "$lin"
mrg="$(new_repo 1.4.0)"
git -C "$mrg" tag v1.4.0; commit "$mrg"; git -C "$mrg" tag v1.4.1
git -C "$mrg" checkout -q -b feature; commit "$mrg"
git -C "$mrg" checkout -q main; commit "$mrg"
git -C "$mrg" merge -q --no-ff feature -m "merge feature"
git -C "$mrg" checkout -q -b other; commit "$mrg"; git -C "$mrg" checkout -q main
git -C "$mrg" merge -q --no-ff other -m "merge other"
run "$lin" release; a="$(val SHORT)/$(val BUILD)"
run "$mrg" release; b="$(val SHORT)/$(val BUILD)"
[[ "$a" == "$b" && "$a" == "1.4.2/1004002" ]] && ok || fail "линейная: $a, с мержами: $b"
run "$lin"; a="$(val SHORT)/$(val BUILD)"
run "$mrg"; b="$(val SHORT)/$(val BUILD)"
[[ "$a" == "$b" && "$a" == "1.4.1/1004001" ]] && ok || fail "dev: линейная $a, с мержами $b"

CASE="тег на коммите другой ветки (как merge в main): dev берёт максимальный тег линии, а не describe"
d="$(new_repo 1.4.0)"
git -C "$d" checkout -q -b development; commit "$d"
git -C "$d" checkout -q main; commit "$d"; git -C "$d" tag v1.4.0
git -C "$d" checkout -q development
run "$d"; expect_success; expect SHORT 1.4.0
git -C "$d" checkout -q main; commit "$d"; git -C "$d" tag v1.4.1
git -C "$d" checkout -q development
run "$d"; expect SHORT 1.4.1

# ---------------------------------------------------------------------------
CASE="без git (архив исходников): BASE.0, dev, COMMIT=unknown"
d="$(mktemp -d "$WORK/nogit.XXXXXX")"
mkdir -p "$d/scripts" "$d/Resources"
cp "$SCRIPT" "$d/scripts/version.sh"; chmod +x "$d/scripts/version.sh"
write_plist "$d" 1.4.0
run "$d"
expect_success; expect SHORT 1.4.0; expect BUILD 1004000; expect CHANNEL dev; expect COMMIT unknown
run "$d" release
expect_error

# ---------------------------------------------------------------------------
echo "test-version.sh: прошло $PASS проверок, провалено $FAIL"
[[ $FAIL -eq 0 ]]
