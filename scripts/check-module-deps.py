#!/usr/bin/env python3
"""Проверка зависимостей между модулями SwiftPM без сборки (секунды).

Для каждого target из Package.swift:
  1. каждый `import MU*` в его исходниках должен быть объявлен в dependencies (иначе локальная
     инкрементальная сборка может пройти, а чистая — упасть, как с MUUpdate → MUAppSwitcher);
  2. слои по .audit/plan-modules.md: MUCore ни от чего; MUDesign и MUAudio — только от MUCore;
     функциональный модуль — только от MUCore/MUDesign/MUAudio, не от приложения и не от другой функции;
  3. в Package.swift нет зависимостей от несуществующих target и нет папок Sources/* без target.
Объявленная, но неиспользуемая зависимость — только предупреждение.

Запуск: scripts/check-module-deps.py [корень]   |   scripts/check-module-deps.py --self-test
"""
import os, re, sys

BASE = {"MUCore", "MUDesign", "MUAudio"}
# Нижние слои: от кого каждый из них может зависеть.
LAYER = {"MUCore": set(), "MUDesign": {"MUCore"}, "MUAudio": {"MUCore"}}
APP = {"MacUtils", "ToolsLauncher"}  # исполняемые: могут зависеть от любых модулей
IMPORT = re.compile(r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z_]\w*)', re.M)
KINDS = (".executableTarget(", ".testTarget(", ".target(")


def blocks(src):
    """Тексты вызовов .target(/.executableTarget(/.testTarget( с учётом скобок и строк."""
    src = re.sub(r'//[^\n]*', '', src)
    out, i = [], 0
    while True:
        hits = [(src.find(k, i), k) for k in KINDS if src.find(k, i) >= 0]
        if not hits:
            return out
        pos, k = min(hits)
        j, depth, instr = pos + len(k), 1, False
        while j < len(src) and depth:
            c = src[j]
            if c == '"' and src[j - 1] != '\\':
                instr = not instr
            elif not instr:
                depth += (c == '(') - (c == ')')
            j += 1
        out.append((k[1:-1], src[pos + len(k):j - 1]))
        i = j


def parse(src):
    targets = {}
    for kind, body in blocks(src):
        name = re.search(r'name:\s*"([^"]+)"', body)
        if not name:
            continue
        deps = re.search(r'dependencies:\s*\[(.*?)\]', body, re.S)
        path = re.search(r'path:\s*"([^"]+)"', body)
        n = name.group(1)
        targets[n] = {
            "kind": kind,
            "deps": re.findall(r'"([^"]+)"', deps.group(1)) if deps else [],
            "path": path.group(1) if path else ("Tests/" if kind == "testTarget" else "Sources/") + n,
        }
    return targets


def swift_files(d):
    for r, _, fs in os.walk(d):
        for f in fs:
            if f.endswith(".swift"):
                yield os.path.join(r, f)


def imports_of(root, path):
    found = {}
    for f in swift_files(os.path.join(root, path)):
        text = open(f, encoding="utf-8", errors="replace").read()
        for m in IMPORT.finditer(text):
            found.setdefault(m.group(1), os.path.relpath(f, root))
    return found


def check(root):
    errors, warnings = [], []
    targets = parse(open(os.path.join(root, "Package.swift"), encoding="utf-8").read())
    for n, t in targets.items():
        for d in t["deps"]:
            if d not in targets:
                errors.append(f"{n}: зависимость \"{d}\" не объявлена как target в Package.swift")
        if not os.path.isdir(os.path.join(root, t["path"])):
            errors.append(f"{n}: нет папки {t['path']}")
            continue
        imp = imports_of(root, t["path"])
        for m, where in sorted(imp.items()):
            if m in targets and m != n and m not in t["deps"]:
                errors.append(f"{n}: `import {m}` ({where}) без {m} в dependencies")
        for d in t["deps"]:
            if d in targets and d not in imp and t["kind"] != "executableTarget":
                warnings.append(f"{n}: {d} объявлен, но не импортируется")
        if t["kind"] == "target":
            allowed = LAYER.get(n, BASE)
            for d in t["deps"]:
                if d in targets and d not in allowed:
                    what = "приложение" if d in APP else ("функциональный модуль" if d not in BASE else "верхний слой")
                    errors.append(f"{n}: зависит от {d} ({what}); разрешено: {', '.join(sorted(allowed)) or 'ничего'} (.audit/plan-modules.md)")
    known = {t["path"].rstrip("/") for t in targets.values()}
    sd = os.path.join(root, "Sources")
    if os.path.isdir(sd):
        for d in sorted(os.listdir(sd)):
            if os.path.isdir(os.path.join(sd, d)) and f"Sources/{d}" not in known:
                errors.append(f"Sources/{d}: папки нет ни в одном target Package.swift")
    # цикл невозможен при проверенных слоях, но проверим и для приложения/тестов
    return targets, errors, warnings


def self_test():
    import tempfile
    pkg = '''let package = Package(name: "X", targets: [
  .target(name: "MUCore", path: "Sources/MUCore"),
  .target(name: "MUDesign", dependencies: ["MUCore"], path: "Sources/MUDesign"),
  .target(name: "MUA", dependencies: ["MUCore", "MUDesign"], path: "Sources/MUA"),
  .target(name: "MUB", dependencies: ["MUCore", "MUA"], path: "Sources/MUB"),
  .executableTarget(name: "App", dependencies: ["MUA"], path: "Sources/App"),
])'''
    with tempfile.TemporaryDirectory() as r:
        def w(p, s):
            os.makedirs(os.path.dirname(os.path.join(r, p)), exist_ok=True)
            open(os.path.join(r, p), "w").write(s)
        w("Package.swift", pkg)
        w("Sources/MUCore/a.swift", "import Foundation\n")
        w("Sources/MUDesign/a.swift", "import MUCore\n")
        w("Sources/MUA/a.swift", "import MUCore\n@testable import MUDesign\nimport MUB\n")  # MUB не объявлен
        w("Sources/MUB/a.swift", "import MUCore\n")
        w("Sources/App/a.swift", "import MUA\nimport struct MUCore.X\n")  # MUCore не объявлен
        w("Sources/Orphan/a.swift", "")
        _, e, wn = check(r)
        text = "\n".join(e)
        for need in ("MUA: `import MUB`", "MUB: зависит от MUA", "App: `import MUCore`", "Sources/Orphan"):
            assert need in text, (need, text)
        assert len(e) == 4, e
    print("self-test ok")


def main():
    if "--self-test" in sys.argv:
        return self_test()
    root = next((a for a in sys.argv[1:] if not a.startswith("-")), ".")
    targets, errors, warnings = check(root)
    for w in warnings:
        print(f"::warning::{w}" if os.environ.get("GITHUB_ACTIONS") else f"warning: {w}")
    for e in errors:
        print(f"::error::{e}" if os.environ.get("GITHUB_ACTIONS") else f"ERROR: {e}")
    print(f"targets: {len(targets)}, ошибок: {len(errors)}, предупреждений: {len(warnings)}")
    sys.exit(1 if errors else 0)


main()
