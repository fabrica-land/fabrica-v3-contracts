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

# The four Sepolia probe transactions. These are literal receipts, not derived: they are the only
# inputs here that cannot be recomputed, so they are pinned with their transaction hashes and every
# figure quoted against them is derived from the arms report at generation time.
SEPOLIA_PROBES = {
    "arm3": (105_591, "arm 3 ownerless store", "0xfdfbed934c8f9d520914b1086230b6dbfac8d7f072d89edc4f1cb38f86121dfd"),
    "arm1C": (201_606, "arm 1C `oracleContext`", "0xec047aff0b6018e7ac9d6d0706b70914c8b1f7cabae44cadd5b839453ea3990f"),
    "arm2": (222_051, "arm 2 EAS plus pointer", "0xc483756a4f39162a42171a90e8122aaa08ac92c4ced59ec6eccf207adf702602"),
    "arm1": (266_120, "arm 1 all-EAS `Indexer`", "0x1cf3a43422292a479ed5bcc91f332512a7c0468744bffcbdf00f88a836abd81c"),
}

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


def read_close_row_depths():
    found = {}
    for match in re.finditer(r"cycle-close row depth (\d+): (\d+)", ARMS):
        found[int(match.group(1))] = int(match.group(2))
    for depth in (1, 3, 7):
        if depth not in found:
            sys.exit(f"derive.py: cycle-close row depth {depth} missing from the arms report")
    return found


def replace_block(path, marker, body):
    text = path.read_text()
    start = f"<!-- GENERATED:{marker} do not edit by hand; bench-reports/regenerate.sh rewrites this -->"
    end = f"<!-- /GENERATED:{marker} -->"
    if start not in text or end not in text:
        sys.exit(f"derive.py: markers for {marker} not found in {path.name}")
    head = text[: text.index(start) + len(start)]
    tail = text[text.index(end):]
    # Markdown tables need a blank line before and after them (markdownlint MD058), and
    # every generated body here starts with one.
    path.write_text(head + "\n\n" + body + "\n\n" + tail)


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

    # Fork against chain. The fork column and every percentage are derived; only the Sepolia
    # column is literal. K1 in review was this table going stale one table over from the last
    # one that went stale, so it is generated now rather than maintained.
    compare = [
        "| Arm | Fork | Sepolia | Difference |",
        "| -- | -- | -- | -- |",
    ]
    for key in ("arm3", "arm1C", "arm2", "arm1"):
        fork = rows[key][0]
        chain, label, _ = SEPOLIA_PROBES[key]
        pct = (chain - fork) / fork * 100
        cell = f"{pct:+.1f}%".replace("+-", "-").replace("-", "\u2212") if pct < 0 else f"+{pct:.1f}%"
        if key == "arm1":
            cell = f"**{cell}**"
        compare.append(f"| {label} | {fork:,} | {chain:,} | {cell} |")
    close = read_close_row_depths()
    per_close = (close[7] - close[1]) // 6
    arm1_pct = (SEPOLIA_PROBES["arm1"][0] - rows["arm1"][0]) / rows["arm1"][0] * 100
    others = [
        abs((SEPOLIA_PROBES[k][0] - rows[k][0]) / rows[k][0] * 100) for k in ("arm3", "arm1C", "arm2")
    ]
    like_pct = (SEPOLIA_PROBES["arm1"][0] - close[3]) / close[3] * 100
    compare += [
        "",
        f"Three arms agree to within {max(others):.1f}%. **Arm 1's {arm1_pct:+.1f}% is not noise, and "
        "chasing it produced a finding** — see below. The price rows on this deployment are fresh at "
        "depth 1, but the writers' CYCLE-CLOSE rows had reached depth 3, one per deployment, because "
        "that row is keyed by the writer rather than by the token. Like for like, the fork at "
        f"cycle-close row depth 3 ({close[3]:,}) against Sepolia at cycle-close row depth 3 "
        f"({SEPOLIA_PROBES['arm1'][0]:,}) is {like_pct:+.1f}%, in line with every other arm.",
    ]
    replace_block(ROOT / "bench-reports" / "eng3922-sepolia-evidence.md", "fork-vs-sepolia", "\n".join(compare))

    close_body = "\n".join(
        [
            "| Cycle-close row depth | arm 1 `price()` gas |",
            "| -- | -- |",
            *[f"| {d} | {close[d]:,} |" for d in (1, 3, 7)],
            "",
            f"About **{per_close:,} gas per extra cycle close**. This row is keyed by the WRITER, not "
            "by the token, so it grows once per cycle for the writer and every `price()` for every "
            "token reads it. At a daily cycle close that is 365 attestations a year on one row, or "
            f"roughly **{per_close * 365:,} gas added to every read** after twelve months.",
        ]
    )
    replace_block(ROOT / "bench-reports" / "eng3922-sepolia-evidence.md", "close-row-depth", close_body)
    print(f"  derived: fork-vs-Sepolia ({len(SEPOLIA_PROBES)} arms, arm1 {arm1_pct:+.1f}%, like-for-like {like_pct:+.1f}%)")
    print(f"  derived: per-hop table (5 arms), Indexer row depth ({first:,} first, {average:,} avg)")


if __name__ == "__main__":
    main()
