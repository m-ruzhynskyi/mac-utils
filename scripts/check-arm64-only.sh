#!/bin/bash
# Проверка: в собранном приложении весь исполняемый код только arm64 (Mac Utils — только Apple Silicon).
# Использование: scripts/check-arm64-only.sh "build/Mac Utils.app"
set -euo pipefail
APP="${1:?путь к .app}"
FAIL=0
COUNT=0
while IFS= read -r -d '' file; do
    file -b "$file" | grep -q "Mach-O" || continue
    COUNT=$((COUNT + 1))
    archs="$(lipo -archs "$file")"
    if [[ "$archs" != "arm64" ]]; then
        echo "::error::Не только arm64 ($archs): ${file#"$APP"/}" >&2
        FAIL=1
    else
        echo "arm64: ${file#"$APP"/}"
    fi
done < <(find "$APP" -type f -perm -u+x -print0; find "$APP" -type f -name '*.dylib' ! -perm -u+x -print0)
(( COUNT > 0 )) || { echo "::error::В $APP нет исполняемого кода" >&2; exit 1; }
exit "$FAIL"
