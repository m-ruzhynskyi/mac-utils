#!/bin/zsh
# Прогон тестовых диалогов подсказчика на настоящем ИИ. Расход подписки: запускает только менеджер.
#   scripts/copilot-eval.sh codex            все диалоги через Codex
#   scripts/copilot-eval.sh claude ru-0      только диалоги, id которых начинается с «ru-0»
# Ответы и оценки: .audit/copilot-eval/<бэкенд>/ (summary.md — сводка, <id>.json — ответ и оценка).
set -e
cd "$(dirname "$0")/.."
backend="${1:?codex или claude}"
export MU_COPILOT_EVAL="$backend"
[ -n "$2" ] && export MU_COPILOT_ONLY="$2"
export MU_COPILOT_OUT="$PWD/.audit/copilot-eval"
lockf -k .audit/build.lock swift test --filter CopilotEvalRunTests
echo "Готово: $MU_COPILOT_OUT/$backend/summary.md"
