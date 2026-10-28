#!/usr/bin/env python3
"""Карта зависимостей модулей: какие типы верхнего уровня одной папки (Core, UI, Features/X, App) используются в других.

  scripts/module-deps.py                  — сводка «откуда → куда (число ссылок)»
  scripts/module-deps.py --from Core      — подробно: файл, тип, где объявлен
  scripts/module-deps.py --dependents Core.Pref — кто использует тип
Глобальные функции считаются только при вызове `name(` без точки перед ним.
"""
import os, re, sys, collections

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Sources", "MacUtils")
DECL = re.compile(r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|package|private|fileprivate|final|indirect)\s+)*"
                  r"(?:(class|struct|enum|protocol|typealias|actor)\s+(\w+)|(func)\s+(\w+))", re.M)


def module(path):
    rel = os.path.relpath(path, ROOT).split(os.sep)
    if rel[0] == "Features":
        return rel[1]
    return rel[0]


def files():
    for d, _, names in os.walk(ROOT):
        for n in names:
            if n.endswith(".swift"):
                yield os.path.join(d, n)


def main():
    decls = {}  # name -> (module, kind, file)
    texts = {}
    for f in files():
        t = open(f, encoding="utf-8").read()
        texts[f] = t
        for m in DECL.finditer(t):
            kind = m.group(1) or m.group(3)
            name = m.group(2) or m.group(4)
            if len(name) < 4:
                continue
            decls.setdefault(name, (module(f), kind, os.path.relpath(f, ROOT)))
    edges = collections.Counter()
    detail = collections.defaultdict(lambda: collections.Counter())
    for f, t in texts.items():
        src = module(f)
        body = re.sub(r"//.*|\"[^\"\n]*\"", "", t)
        for name, (dst, kind, df) in decls.items():
            if dst == src:
                continue
            pat = (r"(?<![\w.])%s\(" if kind == "func" else r"(?<![\w.])%s\b") % re.escape(name)
            n = len(re.findall(pat, body))
            if n:
                edges[(src, dst)] += n
                detail[(src, dst)][(os.path.relpath(f, ROOT), name)] += n
    args = sys.argv[1:]
    if args[:1] == ["--from"]:
        for (s, d), c in sorted(edges.items()):
            if s == args[1]:
                print(f"{s} -> {d}: {c}")
                for (f, name), n in sorted(detail[(s, d)].items()):
                    print(f"    {f}: {name} x{n}")
        return
    if args[:1] == ["--dependents"]:
        mod, name = args[1].split(".")
        for (s, d), c in sorted(edges.items()):
            if d == mod:
                for (f, nm), n in detail[(s, d)].items():
                    if nm == name:
                        print(f"{s}: {f} x{n}")
        return
    for (s, d), c in sorted(edges.items(), key=lambda e: (e[0][0], -e[1])):
        print(f"{s:16} -> {d:16} {c}")
    print(f"\nрёбер: {len(edges)}")


main()
