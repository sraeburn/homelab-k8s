#!/usr/bin/env python3
"""Generate mixed traffic against the todo API so traces, the service map and dashboards have data.

    scripts/traffic.py                         # 2 requests/s until Ctrl-C
    scripts/traffic.py --rps 10 --duration 60  # 10 requests/s for a minute

Each iteration picks a random operation: create (calls notify > audit), list, get, complete (calls
audit), delete (calls audit) or get a missing id (404). Only the standard library is used.
"""
import argparse
import json
import random
import statistics
import threading
import time
import urllib.error
import urllib.request
from collections import Counter

lock = threading.Lock()
ids: list[int] = []
status: Counter = Counter()
latencies: list[float] = []


def call(base, method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            code, payload = resp.status, resp.read()
    except urllib.error.HTTPError as e:
        code, payload = e.code, b""
    except Exception:
        code, payload = 0, b""  # connection error / timeout
    elapsed = (time.perf_counter() - start) * 1000
    with lock:
        status[f"{method} {code}"] += 1
        latencies.append(elapsed)
    return code, payload


def pick_id(pop=False):
    with lock:
        if not ids:
            return None
        return ids.pop(random.randrange(len(ids))) if pop else random.choice(ids)


def create(base):
    code, payload = call(base, "POST", "/api/todos", {"title": f"task {random.randrange(10**6)}"})
    if code == 201:
        with lock:
            ids.append(json.loads(payload)["id"])


def complete(base):
    i = pick_id()
    if i is None:
        return create(base)
    call(base, "PUT", f"/api/todos/{i}", {"title": f"done {i}", "completed": True})


def delete(base):
    i = pick_id(pop=True)
    if i is None:
        return create(base)
    call(base, "DELETE", f"/api/todos/{i}")


def get(base):
    i = pick_id()
    if i is None:
        return create(base)
    call(base, "GET", f"/api/todos/{i}")


OPERATIONS = [  # (function, weight)
    (create, 30),
    (lambda b: call(b, "GET", "/api/todos"), 25),
    (get, 15),
    (complete, 15),
    (delete, 10),
    (lambda b: call(b, "GET", "/api/todos/999999"), 5),
]


def worker(base, interval, deadline, stop):
    funcs, weights = zip(*OPERATIONS)
    next_at = time.monotonic()
    while not stop.is_set() and time.monotonic() < deadline:
        random.choices(funcs, weights)[0](base)
        next_at += interval * random.uniform(0.5, 1.5)  # jitter so requests don't arrive in lockstep
        stop.wait(max(0, next_at - time.monotonic()))


def summary(elapsed):
    total = sum(status.values())
    print(f"\n{total} requests in {elapsed:.0f}s ({total / elapsed:.1f}/s)")
    for key, n in sorted(status.items()):
        print(f"  {key:<12} {n}")
    if latencies:
        q = statistics.quantiles(latencies, n=100) if len(latencies) > 1 else latencies * 99
        print(f"latency ms: p50={q[49]:.0f} p95={q[94]:.0f} p99={q[98]:.0f} max={max(latencies):.0f}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", default="http://todo.k3s.lan", help="todo base URL (default %(default)s)")
    p.add_argument("--rps", type=float, default=2, help="total requests per second (default %(default)s)")
    p.add_argument("--workers", type=int, default=4, help="concurrent workers (default %(default)s)")
    p.add_argument("--duration", type=float, default=0, help="seconds to run; 0 runs until Ctrl-C")
    args = p.parse_args()

    stop = threading.Event()
    start = time.monotonic()
    deadline = start + args.duration if args.duration else float("inf")
    interval = args.workers / args.rps  # each worker sends one request per interval
    threads = [threading.Thread(target=worker, args=(args.url.rstrip("/"), interval, deadline, stop), daemon=True)
               for _ in range(args.workers)]
    print(f"sending ~{args.rps} req/s to {args.url} with {args.workers} workers (Ctrl-C to stop)")
    for t in threads:
        t.start()
    try:
        while any(t.is_alive() for t in threads):
            time.sleep(0.2)
    except KeyboardInterrupt:
        stop.set()
    for t in threads:
        t.join(timeout=11)
    summary(time.monotonic() - start)


if __name__ == "__main__":
    main()
