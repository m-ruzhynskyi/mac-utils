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
nice -n 10 swift build --build-tests > "$WORK/build.txt" 2>&1 || { tail -20 "$WORK/build.txt"; exit 3; }
BUNDLE="$(swift build --show-bin-path)/MacUtilsTests.xctest"
echo "Сборка: $((SECONDS - START)) с"

echo "Прогон по эталону: $JOBS процесса(ов)…"
run_shard() {
    MU_WORD_REF_DIR="$REF" MU_WORD_REF_SHARD="$1/$JOBS" MU_WORD_REF_ONLY="$ONLY" MU_WORD_FIDELITY_TSV="$WORK/part$1.tsv" \
        nice -n 10 xcrun xctest -XCTest MacUtilsTests.WordFidelityTests/testAgainstWordReference "$BUNDLE" > "$WORK/log$1.txt" 2>&1
}
PIDS=()
for ((i = 0; i < JOBS; i++)); do
    run_shard "$i" &
    PIDS+=($!)
done
FAILED=0
for ((i = 0; i < JOBS; i++)); do
    wait "${PIDS[$i]}" && [[ -f "$WORK/part$i.tsv" ]] && continue
    # Процесс могли снять (память, чужой kill) — последняя готовая форма в журнале, затем один повтор.
    echo "Процесс $i прервался после $(grep -o 'word-fidelity f[0-9]*' "$WORK/log$i.txt" | tail -1 | cut -d' ' -f2), повтор…" >&2
    if ! run_shard "$i" || [[ ! -f "$WORK/part$i.tsv" ]]; then
        echo "Процесс $i не завершил прогон и при повторе:" >&2
        grep -E "error|crash|Fatal" "$WORK/log$i.txt" | head -5 >&2 || true
        FAILED=1
    fi
done
[[ $FAILED -eq 0 ]] || exit 3
{ head -1 "$WORK/part0.tsv"; cat "$WORK"/part*.tsv | grep '^f[0-9]' | sort; } > "$WORK/all.tsv"
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
