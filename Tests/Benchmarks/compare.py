#!/usr/bin/env python3
"""Compare two controlled summaries only when their experiment conditions match."""
import argparse
import json
from pathlib import Path


def compare(before, after):
    for report in (before, after):
        if not report.get("comparison_valid"):
            raise ValueError("invalid benchmark: missing path/load/generator validation")
    if before.get("setup") != after.get("setup"):
        raise ValueError("setup or OS differs; do not call this a controlled comparison")
    for key in ("seed", "source_image_sha256", "protocol_sha256", "toolchain", "hardware", "chip", "cpu_count"):
        a, b = before.get("provenance", {}).get(key), after.get("provenance", {}).get(key)
        if a is None or a != b:
            raise ValueError(f"experiment provenance differs: {key}")
    if [p["name"] for p in before["phases"]] != [p["name"] for p in after["phases"]]:
        raise ValueError("phase plans differ")
    phases = []
    for a, b in zip(before["phases"], after["phases"]):
        metrics = {}
        for key in ("fps", "capture_to_decode_p95_ms", "max_gap_ms", "freeze_seconds", "encode_mean_ms", "decode_mean_ms", "sustained_45fps_recovery_seconds"):
            old, new = a.get(key), b.get(key)
            metrics[key] = dict(before=old, after=new, delta=new - old if old is not None and new is not None else None)
        phases.append(dict(name=a["name"], metrics=metrics))
    return dict(comparable=True, phases=phases, before_pass=before["performance_pass"], after_pass=after["performance_pass"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path); parser.add_argument("after", type=Path)
    args = parser.parse_args()
    try:
        result = compare(json.loads(args.before.read_text()), json.loads(args.after.read_text()))
    except ValueError as error:
        parser.exit(1, str(error) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))
