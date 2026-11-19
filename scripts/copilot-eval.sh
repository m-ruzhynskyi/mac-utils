#!/bin/zsh
# Прогон тестовых диалогов подсказчика и замер «конец вопроса → первое слово» (медиана, p90) по сервисам.
#   scripts/copilot-eval.sh <codex|claude|both|stub> [режим] [префикс id]
# codex, claude, both — НАСТОЯЩИЙ ИИ, расход подписки: запускает только менеджер. both — codex, потом claude.
# stub — подставные codex и claude из Tests/Fixtures/Copilot/stub (запросов нет): проверка самого замера.
# Режимы: warm-fast (по умолчанию, как в приложении), warm, cold-fast, cold (CLI на каждый вопрос), hybrid.
#   scripts/copilot-eval.sh both                  оба сервиса, все 24 диалога, как в приложении
#   scripts/copilot-eval.sh claude hybrid ru-0    только диалоги, id которых начинается с «ru-0»
#   MU_COPILOT_REPEAT=2 scripts/copilot-eval.sh claude warm   два круга подряд в одной сессии
# Результат: .audit/copilot-eval/<бэкенд>-<режим>/summary.md и <id>.json; в конце — строки «Задержка …».
set -e
cd "$(dirname "$0")/.."
target="${1:?codex, claude, both или stub}"
mode="${2:-warm-fast}"
[ -n "$3" ] && export MU_COPILOT_ONLY="$3"
[ -n "$MU_COPILOT_REPEAT" ] && export MU_COPILOT_REPEAT
export MU_COPILOT_MODE="$mode"
out="$PWD/.audit/copilot-eval"
lock="${MU_BUILD_LOCK:-$PWD/.audit/build.lock}"   # сборки — под общим замком репозитория
mkdir -p "$out" "$(dirname "$lock")"
case "$target" in
  codex|claude) backends=("$target") ;;
  both) backends=(codex claude) ;;
  stub)
    backends=(codex claude)
    export MU_COPILOT_STUB="$PWD/Tests/Fixtures/Copilot/stub"
    out="$out/stub" ;;
  *) echo "Неизвестно: $target (codex, claude, both или stub)" >&2; exit 2 ;;
esac
export MU_COPILOT_OUT="$out"
for backend in "${backends[@]}"; do
  export MU_COPILOT_EVAL="$backend"
  lockf -k "$lock" swift test --filter 'CopilotEvalRunTests/testRunDialogsOnRealBackend'
done
echo
for backend in "${backends[@]}"; do
  summary="$out/$backend-$mode/summary.md"
  grep -h '^Задержка ' "$summary" || echo "Задержка $backend, $mode: нет сводки ($summary)"
done
echo "Сводки: $out/<бэкенд>-$mode/summary.md"
