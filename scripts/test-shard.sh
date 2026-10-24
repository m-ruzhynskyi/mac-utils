#!/bin/bash
# Запускает долю тестов — шард INDEX из COUNT (CI, задача test-shard в .github/workflows/build.yml).
#   swift build --build-tests && ./scripts/test-shard.sh 0 3
#   SHARD_PRELOAD=0=170 — секунды шарда не на тесты (см. scripts/test-shard.py)
#   SHARD_REPORT=файл   — куда записать «listed= assigned= executed= tree= scope=» для сверки шардов
#   TEST_SCOPE_BASE=SHA — PR: гонять только тесты модулей, затронутых против SHA (scripts/ci-test-scope.py); иначе все
# Падает, если XCTest выполнил не столько тестов, сколько досталось шарду: тест не теряется молча.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 2 ]] || { echo "Использование: $0 INDEX COUNT" >&2; exit 2; }
INDEX="$1"; COUNT="$2"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swift test --skip-build --list-tests > "$WORK/all.txt"
SCOPE=all
if [[ -n "${TEST_SCOPE_BASE:-}" ]]; then
    SCOPE_OUT="$(python3 scripts/ci-test-scope.py --base "$TEST_SCOPE_BASE")"
    echo "$SCOPE_OUT"
    if [[ "$(sed -n 's/^scope=//p' <<< "$SCOPE_OUT")" == "modules" ]]; then
        SCOPE=modules
        TARGETS="$(sed -n 's/^targets=//p' <<< "$SCOPE_OUT")"
        # Строки списка: «Цель.Класс/тест»; оставляем только тесты нужных целей.
        PATTERN="^($(sed 's/,/|/g' <<< "$TARGETS"))\\."
        grep -E "$PATTERN" "$WORK/all.txt" > "$WORK/scoped.txt" || true
        [[ -s "$WORK/scoped.txt" ]] || { echo "::error::В выбранных целях ($TARGETS) нет тестов"; exit 1; }
        mv "$WORK/scoped.txt" "$WORK/all.txt"
        echo "Область: модули $TARGETS"
    fi
fi
PLAN_ARGS=(--weights scripts/test-weights.txt)
[[ -n "${SHARD_PRELOAD:-}" ]] && PLAN_ARGS+=(--preload "$SHARD_PRELOAD")
python3 scripts/test-shard.py "$INDEX" "$COUNT" "${PLAN_ARGS[@]}" < "$WORK/all.txt" > "$WORK/mine.txt"
LISTED=$(wc -l < "$WORK/all.txt" | tr -d ' ')
ASSIGNED=$(wc -l < "$WORK/mine.txt" | tr -d ' ')
echo "Шард $INDEX/$COUNT: $ASSIGNED из $LISTED тестов"

EXECUTED=0
if [[ "$ASSIGNED" -gt 0 ]]; then
    # Имена — только [A-Za-z0-9_./]; точку экранируем, якоря не дают захватить чужой тест по префиксу.
    FILTER="^($(sed 's/\./\\./g' "$WORK/mine.txt" | paste -sd'|' -))\$"
    swift test --skip-build --filter "$FILTER" 2>&1 | tee "$WORK/log.txt"
    # Каждая цель тестов (MacUtilsTests, MURemoteConnectionsTests…) — свой бандл и свой прогон XCTest:
    # складываем итоги всех бандлов («Executed N» сразу после «Test Suite '<цель>.xctest' passed/failed»).
    EXECUTED=$(awk '/^Test Suite .*\.xctest. (passed|failed) at/ { grab = 1; next }
        grab && match($0, /Executed [0-9]+ tests?/) { s += substr($0, RSTART + 9, RLENGTH - 9) + 0; grab = 0 }
        END { print s + 0 }' "$WORK/log.txt")
fi
if [[ -n "${SHARD_REPORT:-}" ]]; then
    echo "listed=$LISTED assigned=$ASSIGNED executed=$EXECUTED tree=$(git rev-parse 'HEAD^{tree}') scope=$SCOPE" > "$SHARD_REPORT"
fi
if [[ "$EXECUTED" != "$ASSIGNED" ]]; then
    echo "::error::Шард $INDEX: выполнено $EXECUTED тестов, а досталось $ASSIGNED"
    exit 1
fi
