#!/bin/zsh
# Прогон тестовых диалогов подсказчика на настоящем ИИ. Расход подписки: запускает только менеджер.
#   scripts/copilot-eval.sh <codex|claude> [режим] [префикс id]
# Режимы: cold (CLI на каждый вопрос, основная модель), cold-fast, warm, warm-fast (по умолчанию в приложении), hybrid.
#   scripts/copilot-eval.sh codex warm-fast          все 24 диалога
#   scripts/copilot-eval.sh claude hybrid ru-0       только диалоги, id которых начинается с «ru-0»
# Результат: .audit/copilot-eval/<бэкенд>-<режим>/summary.md (время и оценки) и <id>.json (ответ).
set -e
cd "$(dirname "$0")/.."
backend="${1:?codex или claude}"
mode="${2:-cold}"
export MU_COPILOT_EVAL="$backend"
export MU_COPILOT_MODE="$mode"
[ -n "$3" ] && export MU_COPILOT_ONLY="$3"
export MU_COPILOT_OUT="$PWD/.audit/copilot-eval"
lockf -k .audit/build.lock swift test --filter CopilotEvalRunTests
echo "Готово: $MU_COPILOT_OUT/$backend-$mode/summary.md"
