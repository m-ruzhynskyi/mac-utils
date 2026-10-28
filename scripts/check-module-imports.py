#!/usr/bin/env python3
"""Каждый модуль Sources/MU* импортирует только то, что объявлено в его зависимостях в Package.swift.
Без этой проверки отладочная сборка SwiftPM пропускает лишний import, а релизная падает (неоднозначные имена)."""
import re, os, glob, sys

pk = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Package.swift")).read()
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
deps = {}
for m in re.finditer(r'\.target\(\s*name: "(\w+)",\s*(?:dependencies: \[([^\]]*)\],\s*)?path', pk):
    deps[m.group(1)] = re.findall(r'"(\w+)"', m.group(2) or "")
bad = []
for mod, allowed in deps.items():
    for f in glob.glob(os.path.join(root, "Sources", mod, "**", "*.swift"), recursive=True):
        for i in re.findall(r"^(?:@testable )?import (MU\w+)$", open(f, encoding="utf-8").read(), re.M):
            if i != mod and i not in allowed:
                bad.append(f"{mod}: {os.path.relpath(f, root)} импортирует {i}, которого нет в зависимостях")
print("\n".join(bad) if bad else f"модулей: {len(deps)}, лишних импортов нет")
sys.exit(1 if bad else 0)
