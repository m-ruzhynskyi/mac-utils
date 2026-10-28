#!/usr/bin/env python3
"""Какие тесты гонять PR: только затронутых модулей или все (CI, scripts/test-shard.sh).
  scripts/ci-test-scope.py --base SHA [--head REV] [--package-json FILE]   # печатает scope=… и targets=…
  scripts/ci-test-scope.py --self-test

Правило: PR меняет только файлы `Sources/MU<Модуль>/` и `Tests/MU<Модуль>Tests/` (каталоги целей из Package.swift) —
тесты гоняются только у тестовых целей, чьё замыкание зависимостей содержит изменённую цель (то есть и у зависимых
модулей, и у сборки приложения, которая зависит от всех). Любой другой файл (общий код, Package.swift, workflow, ресурсы,
скрипты), пустой или непонятный список изменений — все тесты. Сомнение — все тесты.
Цели берутся из `swift package dump-package`; пока в Package.swift нет модулей `MU*`, результат всегда `all`.
"""
import json
import re
import subprocess
import sys

NAME = re.compile(r"^MU[A-Za-z0-9]+$")


def parse_targets(package):
    """{имя: {path, type, deps}} из вывода dump-package."""
    targets = {}
    for t in package.get("targets", []):
        deps = set()
        for d in t.get("dependencies", []):
            for key in ("target", "byName"):
                if key in d:
                    deps.add(d[key][0])
        path = t.get("path") or (("Tests/" if t.get("type") == "test" else "Sources/") + t["name"])
        targets[t["name"]] = {"path": path.rstrip("/"), "type": t.get("type", "regular"), "deps": deps}
    return targets


def closure(targets, name, seen=None):
    seen = seen if seen is not None else set()
    for dep in targets[name]["deps"]:
        if dep in targets and dep not in seen:
            seen.add(dep)
            closure(targets, dep, seen)
    return seen


def scope(changed_files, targets):
    """('all', None) или ('modules', [тестовые цели])."""
    if not changed_files:
        return "all", None
    changed = set()
    for f in changed_files:
        owner = None
        for name, t in targets.items():
            if f.startswith(t["path"] + "/") and (NAME.match(name) or (t["type"] == "test" and NAME.match(name.removesuffix("Tests")))):
                owner = name
                break
        if owner is None:
            return "all", None
        changed.add(owner)
    tests = sorted(n for n, t in targets.items() if t["type"] == "test"
                   and (n in changed or closure(targets, n) & changed))
    # Изменение цели без тестов, которые её видят, — тоже все тесты: так не теряется непокрытый модуль.
    return ("modules", tests) if tests else ("all", None)


def self_test():
    pkg = {"targets": [
        {"name": "MUCore", "type": "regular", "dependencies": []},
        {"name": "MUQR", "type": "regular", "dependencies": [{"byName": ["MUCore", None]}]},
        {"name": "MUAudio", "type": "regular", "dependencies": []},
        {"name": "MUScreenShare", "type": "regular", "dependencies": [{"target": ["MUAudio", None]}]},
        {"name": "MacUtils", "type": "executable", "path": "Sources/MacUtils",
         "dependencies": [{"byName": ["MUQR", None]}, {"byName": ["MUScreenShare", None]}]},
        {"name": "MUQRTests", "type": "test", "dependencies": [{"byName": ["MUQR", None]}]},
        {"name": "MUScreenShareTests", "type": "test", "dependencies": [{"byName": ["MUScreenShare", None]}]},
        {"name": "MUAudioTests", "type": "test", "dependencies": [{"byName": ["MUAudio", None]}]},
        {"name": "MacUtilsAppTests", "type": "test", "path": "Tests/MacUtilsAppTests", "dependencies": [{"byName": ["MacUtils", None]}]},
    ]}
    t = parse_targets(pkg)
    assert scope(["Sources/MUQR/QRView.swift"], t) == ("modules", ["MUQRTests", "MacUtilsAppTests"])
    assert scope(["Sources/MUAudio/Tap.swift"], t) == ("modules", ["MUAudioTests", "MUScreenShareTests", "MacUtilsAppTests"])
    assert scope(["Tests/MUQRTests/QRTests.swift"], t) == ("modules", ["MUQRTests"])
    assert scope(["Sources/MUQR/A.swift", "Tests/MUScreenShareTests/B.swift"], t) == ("modules", ["MUQRTests", "MUScreenShareTests", "MacUtilsAppTests"])
    assert scope(["Sources/MUCore/X.swift"], t)[0] == "modules" and "MUQRTests" in scope(["Sources/MUCore/X.swift"], t)[1]
    for outside in (["Package.swift"], [".github/workflows/build.yml"], ["Sources/MacUtils/App/AppDelegate.swift"],
                    ["Resources/Info.plist"], ["Sources/MUQR/A.swift", "scripts/test-shard.sh"], []):
        assert scope(outside, t) == ("all", None), outside
    assert scope(["Sources/MUQRX/A.swift"], t) == ("all", None), "каталог не цель"
    assert scope(["Sources/MUQR/A.swift"], parse_targets({"targets": [{"name": "MacUtils", "type": "regular"}]})) == ("all", None)
    assert scope(["Sources/MacUtils/A.swift"], parse_targets({"targets": [{"name": "MacUtils", "type": "regular"}]})) == ("all", None), "один target, как сейчас"
    print("ci-test-scope: self-test ok")


def changed_files(base, head):
    out = subprocess.run(["git", "diff", "--name-only", "-z", base, head], check=True, capture_output=True).stdout
    return [p for p in out.decode().split("\0") if p]


def main(argv):
    if "--self-test" in argv:
        return self_test()
    arg = lambda k, d=None: argv[argv.index(k) + 1] if k in argv else d
    base, head = arg("--base"), arg("--head", "HEAD")
    kind, tests = "all", None
    try:
        if base:
            pj = arg("--package-json")
            raw = open(pj).read() if pj else subprocess.run(["swift", "package", "dump-package"], check=True, capture_output=True, text=True).stdout
            kind, tests = scope(changed_files(base, head), parse_targets(json.loads(raw)))
    except Exception as e:  # любая ошибка — все тесты
        print(f"::notice::Область тестов не определена ({e}) — все тесты", file=sys.stderr)
    print(f"scope={kind}")
    print(f"targets={','.join(tests) if tests else ''}")


if __name__ == "__main__":
    main(sys.argv[1:])
