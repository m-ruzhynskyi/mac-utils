#!/usr/bin/env python3
"""Делит список тестов на шарды для CI (задача test-shard в .github/workflows/build.yml).
  swift test --skip-build --list-tests | scripts/test-shard.py INDEX COUNT [--weights FILE] [--preload SHARD=SEC]
  scripts/test-shard.py --self-test

Каждый тест попадает ровно в один шард, раскладка зависит только от списка и файла весов.
Медленные тесты из --weights раскладываются по времени: самый долгий — в самый лёгкий шард.
Остальные — по SHA-1 имени, поэтому новый тест не сдвигает чужие.
--preload — секунды, которые шард тратит не на тесты (шард 0 ещё собирает приложение).
"""
import hashlib
import sys


def read_weights(path):
    weights = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            seconds, name = line.split(None, 1)
            weights[name] = float(seconds)
    return weights


def plan(tests, count, weights=None, preload=None):
    """Номер шарда для каждого теста: {имя: шард}."""
    weights = weights or {}
    load = [0.0] * count
    for shard, seconds in (preload or {}).items():
        load[shard] += seconds
    shards = {}
    slow = sorted((name for name in set(tests) if name in weights), key=lambda n: (-weights[n], n))
    for name in slow:
        shard = load.index(min(load))
        shards[name] = shard
        load[shard] += weights[name]
    for name in tests:
        if name not in shards:
            shards[name] = int(hashlib.sha1(name.encode()).hexdigest(), 16) % count
    return shards


def self_test():
    tests = [f"MacUtilsTests.Case{c}/test{t}" for c in range(40) for t in range(25)]
    weights = {tests[i]: float(200 - i * 5) for i in range(30)}
    weights["MacUtilsTests.Gone/testRemoved"] = 999.0
    for count in (1, 2, 3, 5):
        shards = plan(tests, count, weights, {0: 150.0})
        parts = [[n for n in tests if shards[n] == k] for k in range(count)]
        assert sorted(sum(parts, [])) == sorted(tests), "каждый тест ровно в одном шарде"
        assert set(shards) == set(tests), "в плане только тесты из списка"
        assert shards == plan(list(reversed(tests)), count, weights, {0: 150.0}), "порядок списка не важен"
        slow = [sum(weights.get(n, 0) for n in p) + (150 if k == 0 else 0) for k, p in enumerate(parts)]
        assert max(slow) - min(slow) <= 200, f"медленные разложены ровно: {slow}"
    before = plan(tests, 3, weights)
    after = plan(tests + ["MacUtilsTests.New/testAdded"], 3, weights)
    assert all(after[n] == before[n] for n in tests), "новый тест не сдвигает чужие"
    print("test-shard: self-test ok")


def main(argv):
    if argv == ["--self-test"]:
        self_test()
        return 0
    args, weights, preload = [], {}, {}
    it = iter(argv)
    for arg in it:
        if arg == "--weights":
            weights = read_weights(next(it))
        elif arg == "--preload":
            shard, seconds = next(it).split("=")
            preload[int(shard)] = float(seconds)
        else:
            args.append(arg)
    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    index, count = int(args[0]), int(args[1])
    if not 0 <= index < count:
        print(f"Шард {index} вне 0..{count - 1}", file=sys.stderr)
        return 2
    tests = [line.strip() for line in sys.stdin if line.strip()]
    if not tests:
        print("Пустой список тестов", file=sys.stderr)
        return 1
    if len(set(tests)) != len(tests):
        print("В списке тестов повторы", file=sys.stderr)
        return 1
    shards = plan(tests, count, weights, preload)
    for name in tests:
        if shards[name] == index:
            print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
