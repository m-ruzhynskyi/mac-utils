#!/bin/bash
# Гейт «Документа» против эталона Word — локально у менеджера (формы и PDF Word в CI не попадают,
# .audit/plan-doc-word-parity.md § 4). Один запуск: сборка тестов, все формы параллельно, сводка «было/стало».
#   scripts/word-gate.sh                   — сравнить с базой; код 1, если какая-то форма стала хуже
#   scripts/word-gate.sh --update          — сравнить и записать прогон как новую базу (после принятых улучшений)
#   scripts/word-gate.sh --only f001,f027  — только эти формы (по ходу работы)
#   scripts/word-gate.sh -j 6 --out FILE   — число процессов (по умолчанию 4); куда положить сводку
#   --results FILE                         — сохранить числа прогона (TSV, как база)
# Код выхода: 0 — не хуже базы, 1 — есть формы хуже базы, 3 — прогон не состоялся (сборка, процесс снят).
# MU_WORD_REF_DIR — папка с rtf/ и pdf/ (по умолчанию ~/Projects/Cowork/Form/LAB-word-ref);
# база — $MU_WORD_REF_DIR/baseline.tsv (только числа по fNNN, в репозиторий не коммитится).
# Без окон на экране и без звука: формы раскладываются офскрин в процессах xctest.
set -euo pipefail
cd "$(dirname "$0")/.."

REF="${MU_WORD_REF_DIR:-$HOME/Projects/Cowork/Form/LAB-word-ref}"
JOBS=4; UPDATE=0; ONLY=""; OUT=""; RESULTS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --update) UPDATE=1 ;;
        --only) ONLY="$2"; shift ;;
        --out) OUT="$2"; shift ;;
        --results) RESULTS="$2"; shift ;;
        -j) JOBS="$2"; shift ;;
        *) echo "Использование: $0 [--update] [--only f001,f002] [-j N] [--out FILE]" >&2; exit 2 ;;
    esac
    shift
done
[[ -d "$REF/rtf" && -d "$REF/pdf" ]] || { echo "Нет эталона: нужны rtf/ и pdf/ в MU_WORD_REF_DIR" >&2; exit 2; }
BASELINE="$REF/baseline.tsv"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
START=$SECONDS

echo "Сборка тестов…"
# Сборки команды — по одной (замок build.lock в .audit основного дерева, если он есть; .audit/doc-team-rules.md).
BUILD_LOCK="${MU_BUILD_LOCK:-$(cd "$(git rev-parse --git-common-dir)/.." && pwd)/.audit/build.lock}"
BUILD=(nice -n 20 swift build --build-tests -j 2)
[[ -d "$(dirname "$BUILD_LOCK")" ]] && BUILD=(/usr/bin/lockf -k "$BUILD_LOCK" "${BUILD[@]}")
"${BUILD[@]}" > "$WORK/build.txt" 2>&1 || { tail -20 "$WORK/build.txt"; exit 3; }
BUNDLE="$(swift build --show-bin-path)/MacUtilsTests.xctest"
echo "Сборка: $((SECONDS - START)) с"

echo "Прогон по эталону: $JOBS процесса(ов)…"
# Доля форм в своём процессе xctest. Сторож: нет новой строки журнала дольше FORM_TIMEOUT — форма зависла
# (раскладка не кончается): процесс снимается, форма — провал «зависла», доля продолжается без неё.
# Процесс снят извне (память, kill) — один повтор без уже готовых форм. Числа форм тест дописывает по одной.
FORM_TIMEOUT="${MU_WORD_FORM_TIMEOUT:-120}"
run_shard() {
    local i="$1" part="$WORK/part$1.tsv" log="$WORK/log$1.txt" retried=0
    while true; do
        local skip="" code=0 stall=0 size=-1 now pid hung
        [[ -f "$part" ]] && skip="$(grep -o '^f[0-9]*' "$part" | paste -sd, -)"
        MU_WORD_REF_DIR="$REF" MU_WORD_REF_SHARD="$i/$JOBS" MU_WORD_REF_ONLY="$ONLY" MU_WORD_REF_SKIP="$skip" \
            MU_WORD_FIDELITY_TSV="$part" nice -n 20 xcrun xctest -XCTest MacUtilsTests.WordFidelityTests/testAgainstWordReference \
            "$BUNDLE" >> "$log" 2>&1 &
        pid=$!
        while kill -0 "$pid" 2>/dev/null; do
            sleep 5
            now=$(wc -c < "$log")
            if [[ "$now" != "$size" ]]; then size="$now"; stall=0; else stall=$((stall + 5)); fi
            [[ $stall -ge $FORM_TIMEOUT ]] && break
        done
        if [[ $stall -ge $FORM_TIMEOUT ]]; then
            hung="$(grep -ao 'word-fidelity start f[0-9]*' "$log" | tail -1 | awk '{print $3}')"
            pkill -9 -P "$pid" 2>/dev/null || true
            kill -9 "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            [[ -n "$hung" ]] || return 1
            echo "Форма $hung: раскладка не закончилась за $FORM_TIMEOUT с — провал формы, дальше без неё" >&2
            printf '%s\t2%s\n' "$hung" "$(printf '\t0%.0s' $(seq 13))" >> "$part"
            continue
        fi
        wait "$pid" || code=$?
        [[ $code -eq 0 ]] && return 0
        [[ $retried -eq 0 ]] || return 1
        retried=1
        echo "Процесс $i прервался (код $code) после $(grep -ao 'word-fidelity f[0-9]*:' "$log" | tail -1 | cut -d' ' -f2 | tr -d :), повтор без готовых форм…" >&2
    done
}
PIDS=()
for ((i = 0; i < JOBS; i++)); do
    run_shard "$i" &
    PIDS+=($!)
done
FAILED=0
for ((i = 0; i < JOBS; i++)); do
    if ! wait "${PIDS[$i]}"; then
        echo "Процесс $i не завершил прогон:" >&2
        grep -aE "error|crash|Fatal" "$WORK/log$i.txt" | head -5 >&2 || true
        FAILED=1
    fi
done
[[ $FAILED -eq 0 ]] || exit 3
{ awk '/^file/ { print; exit }' "$WORK"/part*.tsv 2>/dev/null || true; cat "$WORK"/part*.tsv 2>/dev/null | grep '^f[0-9]' | sort; } > "$WORK/all.tsv"
echo "Форм: $(grep -c '^f[0-9]' "$WORK/all.tsv"), всего с начала — $((SECONDS - START)) с"
[[ -z "$RESULTS" ]] || cp "$WORK/all.tsv" "$RESULTS"

if [[ ! -f "$BASELINE" ]]; then
    cp "$WORK/all.tsv" "$BASELINE.tmp" && mv "$BASELINE.tmp" "$BASELINE"
    echo "Базы не было — записана из этого прогона ($BASELINE). Следующий запуск сравнит с ней."
fi

SUMMARY="${OUT:-$WORK/gate.md}"
STATUS=0
MU_WORD_REF_DIR="$REF" MU_WORD_FIDELITY_RESULTS="$WORK/all.tsv" MU_WORD_GATE_OUT="$SUMMARY" MU_WORD_GATE_SECONDS="$((SECONDS - START))" \
    xcrun xctest -XCTest MacUtilsTests.WordFidelityTests/testGateFromResults "$BUNDLE" > "$WORK/gate.txt" 2>&1 || STATUS=1
if [[ -f "$SUMMARY" ]]; then cat "$SUMMARY"; else tail -20 "$WORK/gate.txt"; STATUS=1; fi

if [[ $UPDATE -eq 1 ]]; then
    if [[ -n "$ONLY" ]]; then
        # Частичный прогон: в базе заменяются только эти формы.
        { head -1 "$WORK/all.tsv"
          awk -F'\t' 'NR == FNR { if ($1 ~ /^f[0-9]+$/) { seen[$1] = 1; print } next } $1 ~ /^f[0-9]+$/ && !($1 in seen)' \
              "$WORK/all.tsv" "$BASELINE" | sort; } > "$BASELINE.tmp"
    else
        cp "$WORK/all.tsv" "$BASELINE.tmp"
    fi
    mv "$BASELINE.tmp" "$BASELINE"
    echo "База обновлена: $BASELINE"
    STATUS=0
fi
echo "Время: $((SECONDS - START)) с"
exit $STATUS
