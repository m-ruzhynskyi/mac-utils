#!/bin/bash
# Значки документов в собранном приложении: Info.plist проходит plutil -lint, у каждой записи CFBundleDocumentTypes
# есть CFBundleTypeIconFile, он и UTTypeIconFile указывают на настоящий .icns в Contents/Resources со всеми размерами
# 16–512 @1x/@2x, лишних DocIcon-*.icns нет.
#   ./scripts/check-doc-icons.sh "build/Mac Utils.app"
set -euo pipefail
APP="${1:?usage: check-doc-icons.sh <App.app>}"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
python3 -I - "$APP" <<'PY'
import os, plistlib, subprocess, sys, tempfile

app = sys.argv[1]
resources = os.path.join(app, "Contents", "Resources")
with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
    info = plistlib.load(f)
errors = []
icons = []
for entry in info.get("CFBundleDocumentTypes", []):
    name = entry.get("CFBundleTypeName", "?")
    icon = entry.get("CFBundleTypeIconFile")
    if not icon:
        errors.append(f"{name}: нет CFBundleTypeIconFile")
    else:
        icons.append((name, icon))
for decl in info.get("UTExportedTypeDeclarations", []):
    if decl.get("UTTypeIconFile"):
        icons.append((decl.get("UTTypeIdentifier", "?"), decl["UTTypeIconFile"]))

reps = {f"icon_{s}x{s}{k}.png" for s in (16, 32, 128, 256, 512) for k in ("", "@2x")}
checked = set()
for owner, icon in icons:
    file = icon if icon.endswith(".icns") else icon + ".icns"
    path = os.path.join(resources, file)
    if not os.path.isfile(path):
        errors.append(f"{owner}: нет файла {file}")
        continue
    if file in checked:
        continue
    checked.add(file)
    with open(path, "rb") as f:
        if f.read(4) != b"icns":
            errors.append(f"{file}: не icns")
            continue
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "x.iconset")
        result = subprocess.run(["/usr/bin/iconutil", "-c", "iconset", path, "-o", out], capture_output=True, text=True)
        missing = reps - set(os.listdir(out)) if result.returncode == 0 else reps
        if missing:
            errors.append(f"{file}: нет размеров {sorted(missing)}")

extra = sorted(f for f in os.listdir(resources) if f.startswith("DocIcon-") and f not in checked)
if extra:
    errors.append(f"лишние значки без записи в Info.plist: {extra}")
if errors:
    for e in errors:
        print(f"::error::{e}" if os.environ.get("GITHUB_ACTIONS") else e, file=sys.stderr)
    sys.exit(1)
size = sum(os.path.getsize(os.path.join(resources, f)) for f in checked)
print(f"Значки документов: {len(checked)} файлов, {size / 1024 / 1024:.2f} МБ, записей {len(icons)}")
PY
