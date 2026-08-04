#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

IMPORT_LINE = "import { registerSnapshotRoute } from './snapshot.js';\n"
REGISTER_LINE = "registerSnapshotRoute(app);\n"
FAST_SNAPSHOT_MARKERS = (
    "async function latestCompletedLiveSegment",
    "const SNAPSHOT_CACHE_TTL_MS",
    "const SNAPSHOT_STALE_MAX_AGE_MS",
    "const snapshotJobs = new Map",
    "x-newdomofon-snapshot-cache",
    "source: 'live-segment'",
)


def patch_index(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    changed = False

    if IMPORT_LINE not in text:
        anchor = "import { registerLiveTsRelayRoutes } from './liveTsRelay.js';\n"
        if anchor not in text:
            raise RuntimeError("liveTsRelay import anchor was not found")
        text = text.replace(anchor, anchor + IMPORT_LINE, 1)
        changed = True

    if REGISTER_LINE not in text:
        anchor = "registerLiveTsRelayRoutes(app);\n"
        if anchor not in text:
            raise RuntimeError("liveTsRelay registration anchor was not found")
        text = text.replace(anchor, anchor + REGISTER_LINE, 1)
        changed = True

    if changed:
        path.write_text(text, encoding="utf-8")

    if text.count(IMPORT_LINE) != 1:
        raise RuntimeError(f"unexpected snapshot import count: {text.count(IMPORT_LINE)}")
    if text.count(REGISTER_LINE) != 1:
        raise RuntimeError(f"unexpected snapshot registration count: {text.count(REGISTER_LINE)}")

    return changed


def validate_snapshot(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    missing = [marker for marker in FAST_SNAPSHOT_MARKERS if marker not in text]
    if missing:
        raise RuntimeError(f"fast snapshot runtime markers are missing: {', '.join(missing)}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-node")
    args = parser.parse_args()

    project = Path(args.project_dir).resolve()
    index = project / "dvr-engine" / "src" / "index.ts"
    snapshot = project / "dvr-engine" / "src" / "snapshot.ts"

    if not index.is_file():
        raise SystemExit(f"DVR index source not found: {index}")
    if not snapshot.is_file():
        raise SystemExit(f"Snapshot source not found: {snapshot}")

    changed = patch_index(index)
    validate_snapshot(snapshot)
    print("SmartYard snapshot route prepared" if changed else "SmartYard snapshot route already prepared")
    print("Fast snapshot cache runtime validated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())