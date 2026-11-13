#!/usr/bin/env python3
"""Test the daily limit, the tripwire and the limit checks, using a queue no runner reads ("queue:budget-test").

It changes the ConfigMap "agent-limits" and the platform state while it runs and puts both back at the end,
together with today's counter. Run it only while no real task is waiting.   Usage: tests/budget-test.py
"""
import concurrent.futures, importlib.machinery, importlib.util, os, subprocess, sys

here = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("labctl", os.path.join(here, "..", "labctl"))
lab = importlib.util.module_from_spec(importlib.util.spec_from_loader("labctl", loader))
loader.exec_module(lab)

def set_cm(**values):
    patch = '{"data":{' + ",".join(f'"{k}":"{v}"' for k, v in values.items()) + "}}"
    rc, _out, err = lab.kubectl("-n", "agents", "patch", "configmap", "agent-limits", "--type", "merge", "-p", patch)
    assert rc == 0, err
def labctl(*args):
    p = subprocess.run([os.path.join(here, "..", "labctl"), *args], capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()
def counter():
    return lab.redis("GET", KEY)[0] or "0"
def put(n):
    return lab.enqueue("budget-test", f"t-test-{n}", {"id": f"t-test-{n}"})[0]
def show(name, got, expected):
    print(f"{'PASS' if got == expected else 'FAIL'}  {name}: {got}" + ("" if got == expected else f"   (expected {expected})"))
    return got == expected

original = lab.limits()
KEY = f"count:{int(lab.redis('TIME')[0]) // 86400}"
saved_counter, saved_state = lab.redis("GET", KEY)[0], lab.platform_state()
ok = True
try:
    lab.redis("DEL", KEY, "queue:budget-test")
    set_cm(dailyTaskLimit=3)
    labctl("agents", "on")
    ok &= show("1. three tasks under a limit of 3", [put(i) for i in (1, 2, 3)], ["ok", "ok", "ok"])
    ok &= show("1. counter", counter(), "3")
    ok &= show("2. fourth task", put(4), "limit")
    ok &= show("2. tripwire: platform after the refused task", lab.platform_state(), "off")
    ok &= show("2. counter unchanged", counter(), "3")
    ok &= show("2. queue length", lab.redis("LLEN", "queue:budget-test")[0], "3")

    lab.redis("DEL", KEY, "queue:budget-test")
    labctl("agents", "on")
    with concurrent.futures.ThreadPoolExecutor(5) as pool:
        results = sorted(pool.map(put, range(10, 15)))
    ok &= show("3. five at the same time, limit 3", results, ["limit", "limit", "ok", "ok", "ok"])
    ok &= show("3. counter", counter(), "3")

    lab.redis("DEL", KEY, "queue:budget-test")
    labctl("agents", "off")
    ok &= show("4. platform off: task", put(20), "off")
    ok &= show("4. counter", counter(), "0")

    for bad in ("abc", "0", "9999", ""):
        set_cm(dailyTaskLimit=bad)
        rc, out = labctl("budget")
        ok &= show(f"5. dailyTaskLimit={bad!r}: labctl budget exit code", rc, 1)
        rc, out = labctl("agents", "on")
        ok &= show(f"5. dailyTaskLimit={bad!r}: agents on refused, platform", (rc, lab.platform_state()), (1, "off"))
finally:
    set_cm(**original)
    lab.redis("DEL", "queue:budget-test", *[f"task:budget-test:t-test-{n}" for n in (1, 2, 3, 4, 10, 11, 12, 13, 14, 20)])
    lab.redis("SET", KEY, saved_counter) if saved_counter else lab.redis("DEL", KEY)
    labctl("agents", "on" if saved_state == "on" else "off")
    print(f"restored: limits {lab.limits()}, counter {counter()}, platform {lab.platform_state()}")
sys.exit(0 if ok else 1)
