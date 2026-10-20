#!/bin/bash
# Запускает долю тестов — шард INDEX из COUNT (CI, задача test-shard в .github/workflows/build.yml).
#   swift build --build-tests && ./scripts/test-shard.sh 0 3
#   SHARD_PRELOAD=0=170 — секунды шарда не на тесты (см. scripts/test-shard.py)
#   SHARD_REPORT=файл   — куда записать «listed= assigned= executed= tree=» для сверки шардов
# Падает, если XCTest выполнил не столько тестов, сколько досталось шарду: тест не теряется молча.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 2 ]] || { echo "Использование: $0 INDEX COUNT" >&2; exit 2; }
INDEX="$1"; COUNT="$2"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swift test --skip-build --list-tests > "$WORK/all.txt"
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
    EXECUTED=$(grep -oE 'Executed [0-9]+ tests?' "$WORK/log.txt" | tail -1 | grep -oE '[0-9]+' || echo 0)
fi
if [[ -n "${SHARD_REPORT:-}" ]]; then
    echo "listed=$LISTED assigned=$ASSIGNED executed=$EXECUTED tree=$(git rev-parse 'HEAD^{tree}')" > "$SHARD_REPORT"
fi
if [[ "$EXECUTED" != "$ASSIGNED" ]]; then
    echo "::error::Шард $INDEX: выполнено $EXECUTED тестов, а досталось $ASSIGNED"
    exit 1
fi
