#!/usr/bin/env python3
"""Summarize health.log: alert counts per check and the latest metrics.

Usage: python3 report.py [--log logs/health.log] [--hours 24]
"""
import argparse
import re
from collections import Counter
from datetime import datetime, timedelta

LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) host=(\S+) level=(\S+) check=(\S+)\s*(.*)$")


def parse(path):
    with open(path) as fh:
        for raw in fh:
            m = LINE.match(raw.strip())
            if not m:
                continue
            when = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
            fields = dict(kv.split("=", 1) for kv in m.group(5).split() if "=" in kv)
            yield when, m.group(2), m.group(3), m.group(4), fields, m.group(5)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default="logs/health.log")
    ap.add_argument("--hours", type=int, default=24)
    args = ap.parse_args()
    if args.hours < 1:
        ap.error("--hours must be at least 1")

    try:
        rows = list(parse(args.log))
    except OSError as exc:
        ap.error(f"cannot read log {args.log!r}: {exc}")

    cutoff = datetime.now() - timedelta(hours=args.hours)
    alerts = Counter()
    latest = {}
    runs = 0
    for when, host, level, check, fields, rest in rows:
        if when < cutoff:
            continue
        if check == "run" and rest.startswith("start"):
            runs += 1
        if level in ("WARN", "CRIT"):
            alerts[(check, level)] += 1
        if check in ("disk", "memory", "swap", "load"):
            key = (check, fields.get("mount", ""))
            latest[key] = (when, fields)

    print(f"Health report - last {args.hours}h ({runs} runs)")
    print("-" * 44)
    if alerts:
        for (check, level), n in sorted(alerts.items()):
            print(f"{level:<5} {check:<10} {n} occurrence(s)")
    else:
        print("No warnings or critical alerts.")
    print("\nLatest readings:")
    for (check, mount), (when, f) in sorted(latest.items()):
        label = f"{check} {mount}".strip()
        value = f.get("used_pct") or f.get("per_cpu") or "?"
        print(f"  {label:<18} {value}  ({when:%H:%M:%S})")


if __name__ == "__main__":
    main()
