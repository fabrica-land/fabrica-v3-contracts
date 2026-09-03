#!/usr/bin/env python3
"""Emit every figure that is DERIVED from bench-reports/eng3922-arms.txt.

Round 3 of review found the seasoning-walk per-hop table stale: it was derived from the arms
report but typed by hand, so it survived a report regeneration unchanged. Everything derived is
now written from here, between explicit markers, so it cannot drift from its source again.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ARMS = (ROOT / "bench-reports" / "eng3922-arms.txt").read_text()

ARM_LABELS = [
    ("arm3", "arm3 ownerless store   ", "arm 3 ownerless custom store"),
    ("cal", "cal. round-1 store     ", "calibration round-1 store"),
    ("arm1C", "arm1C EAS oracleContext", "arm 1C all-EAS `oracleContext`"),
    ("arm2", "arm2 EAS+pointer       ", "arm 2 EAS plus pointer"),
    ("arm1", "arm1 all-EAS indexer   ", "arm 1 all-EAS `Indexer`"),
]
DEPTHS = (0, 1, 3, 7)


def read_depths(needle):
    found = {}
    for match in re.finditer(
        re.escape(needle) + r"\s+depth/source=(\d+) price\(\) execution gas: (\d+)", ARMS
    ):
        found[int(match.group(1))] = int(match.group(2))
    missing = [d for d in DEPTHS if d not in found]
    if missing:
        sys.exit(f"derive.py: {needle.strip()} missing walk depths {missing} in the arms report")
    return found


def read_row_depths():
    found = {}
    for match in re.finditer(r"Indexer row depth (\d+): (\d+)", ARMS):
        found[int(match.group(1))] = int(match.group(2))
    for depth in (1, 2, 5):
        if depth not in found:
            sys.exit(f"derive.py: Indexer row depth {depth} missing from the arms report")
    return found


def replace_block(path, marker, body):
    text = path.read_text()
    start = f"<!-- GENERATED:{marker} do not edit by hand; bench-reports/regenerate.sh rewrites this -->"
    end = f"<!-- /GENERATED:{marker} -->"
    if start not in text or end not in text:
        sys.exit(f"derive.py: markers for {marker} not found in {path.name}")
    head = text[: text.index(start) + len(start)]
    tail = text[text.index(end):]
    path.write_text(head + "\n" + body + "\n" + tail)


def main():
    rows = {key: read_depths(needle) for key, needle, _ in ARM_LABELS}
    per_hop = {}
    lines = [
        "| Arm | depth 0 | depth 1 | depth 3 | depth 7 | per hop 0→1 | 1→3 | 3→7 |",
        "| -- | -- | -- | -- | -- | -- | -- | -- |",
    ]
    for key, _, label in ARM_LABELS:
        d = rows[key]
        hops = ((d[1] - d[0]) // 3, (d[3] - d[1]) // 6, (d[7] - d[3]) // 12)
        per_hop[key] = hops
        cells = " | ".join(f"{d[x]:,}" for x in DEPTHS)
        hop_cells = " | ".join(f"{h:,}" for h in hops)
        lines.append(f"| {label} | {cells} | {hop_cells} |")
    store_hops = per_hop["arm3"] + per_hop["cal"]
    eas_hops = per_hop["arm1C"] + per_hop["arm2"] + per_hop["arm1"]
    lines += [
        "",
        f"So the honest statement is a range, not a point: **{min(store_hops):,} to {max(store_hops):,} gas "
        f"per hop on a custom store and {min(eas_hops):,} to {max(eas_hops):,} on the EAS arms**, with the "
        "first hop dearer on every arm because it is the one that pays cold access to the history slot or "
        'the referenced attestation. A single "~46,700" figure appeared in an earlier draft of this '
        "document; it did not trace to any row, and it is withdrawn.",
    ]
    replace_block(ROOT / "bench-reports" / "eng3922-write-time-guards.md", "seasoning-walk-per-hop", "\n".join(lines))

    depth = read_row_depths()
    first = depth[2] - depth[1]
    average = (depth[5] - depth[2]) // 3
    body = "\n".join(
        [
            "| Indexer row depth | arm 1 `price()` gas |",
            "| -- | -- |",
            *[f"| {d} | {depth[d]:,} |" for d in (1, 2, 5)],
            "",
            f"That is **{first:,} gas for the first extra attestation and about {average:,} per attestation "
            f"averaged over depths 2 to 5** — it is not one constant, and quoting it as a single figure "
            "understates how it grows.",
        ]
    )
    replace_block(ROOT / "bench-reports" / "eng3922-sepolia-evidence.md", "indexer-row-depth", body)
    print(f"  derived: per-hop table (5 arms), Indexer row depth ({first:,} first, {average:,} avg)")


if __name__ == "__main__":
    main()
