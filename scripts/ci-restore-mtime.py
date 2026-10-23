#!/usr/bin/env python3
"""Ставит отслеживаемым git файлам время изменения, зависящее только от содержимого (CI, кэш `.build`).
  scripts/ci-restore-mtime.py [--check]

После `actions/checkout` у всех файлов время — «сейчас», и SwiftPM пересобирает всё, даже если кэш `.build`
восстановлен. Здесь mtime = функция SHA-1 содержимого: тот же файл — то же время (сборка из кэша их пропускает),
изменённый файл получает другое время (пересобирается). От истории git и часов раннера это не зависит.
Время лежит в 2008–2023 годах: «из будущего» не бывает. Кэш только ускоряет: при любом расхождении SwiftPM пересоберёт файл.
"""
import hashlib
import os
import subprocess
import sys

BASE = 1_200_000_000
SPAN = 500_000_000


def stamp(path):
    with open(path, "rb") as f:
        digest = hashlib.sha1(f.read()).digest()
    return BASE + int.from_bytes(digest[:8], "big") % SPAN


def tracked():
    out = subprocess.run(["git", "ls-files", "-z"], check=True, capture_output=True).stdout
    return [p for p in out.decode().split("\0") if p and os.path.isfile(p) and not os.path.islink(p)]


def main():
    check = "--check" in sys.argv
    changed = 0
    for path in tracked():
        t = stamp(path)
        if int(os.stat(path).st_mtime) != t:
            changed += 1
            if not check:
                os.utime(path, (t, t))
    print(f"ci-restore-mtime: {'не совпадает' if check else 'выставлено'} у {changed} файлов")
    if check and changed:
        sys.exit(1)


if __name__ == "__main__":
    main()
