#!/usr/bin/env python3
"""Check effective Windows cache budgets before comparing functional runs.

Uses the upstream comparator and its unchanged correctness/timing gates. An
explicit RAM-cache request must be honored in both server processes, and all
arms must use the same effective RAM, staging and disk capacities.
"""

import argparse
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tests" / "functional"))
import compare  # noqa: E402
from run import option  # noqa: E402


def cache_budgets(directory):
    directory = Path(directory)
    report = json.loads((directory / "report.json").read_text())
    requested = int(option(report["command"], "--cache-ram-bytes", "0"))
    logs = ["server.log"]
    if "restart_ms" in report:
        logs.append("server-restarted.log")
    budgets = {}
    for name in logs:
        configurations = []
        for line in (directory / name).read_text().splitlines():
            fields = dict(re.findall(r"\b(\w+)=(\S+)", line))
            if fields.get("schema") == "component-cache-v1" \
                    and fields.get("event") == "configured":
                configurations.append({key: int(fields[key]) for key in (
                    "capacity_bytes", "staging_capacity_bytes", "disk_capacity_bytes")})
        if len(configurations) != 1:
            raise ValueError(f"{directory}/{name}: expected one component-cache configuration")
        budget = configurations[0]
        if requested and budget["capacity_bytes"] != requested:
            raise ValueError(f"{directory}/{name}: requested RAM cache {requested}, "
                             f"configured {budget['capacity_bytes']}; run is not matched")
        budgets[name] = budget
    return budgets


def validate_budgets(pairs, controls=()):
    evidence = {}
    reference = None
    for before, after in [*pairs, *controls]:
        for path in (before, after):
            path = str(Path(path).resolve())
            if path in evidence:
                continue
            budgets = cache_budgets(path)
            if reference is not None and budgets != reference:
                raise ValueError(f"{path}: effective cache budgets differ from the initial run")
            reference = budgets
            evidence[path] = budgets
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pair", nargs=2, type=Path, action="append", required=True)
    parser.add_argument("--control", nargs=2, type=Path, action="append", default=[])
    parser.add_argument("--output", type=Path, required=True, help="New JSON evidence file")
    args = parser.parse_args()
    try:
        budgets = validate_budgets(args.pair, args.control)
        result = compare.evidence(args.pair, args.control)
        result["effective_cache_budgets"] = budgets
    except (ValueError, KeyError, OSError) as error:
        result = {"status": "failed", "error": str(error), "measurements": []}
    with args.output.open("x") as output:
        output.write(json.dumps(result, indent=2) + "\n")
    print(f"{result['status']}: {args.output}")
    return {"passed": 0, "failed": 1, "inconclusive": 2}[result["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
