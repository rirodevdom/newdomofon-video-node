#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

CONSTANT = "const maxArchivePlaybackSeconds = Math.max(config.maxExportSeconds, Number(process.env.DVR_ARCHIVE_PLAYBACK_MAX_SECONDS || 3 * 60 * 60));\n"
OLD_ROUTE = "    const range = parseRange(req, res);\n    if (!range) return;\n    const segments = await listSegments(req.params.streamName, range.start, range.end);\n"
NEW_ROUTE = "    const range = parseRange(req, res, maxArchivePlaybackSeconds);\n    if (!range) return;\n    const segments = await listSegments(req.params.streamName, range.start, range.end);\n"


def patch_index(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    changed = False

    if CONSTANT not in text:
        anchor = "const maxArchiveRangesSeconds = Math.max(config.maxExportSeconds, Number(process.env.DVR_ARCHIVE_RANGES_MAX_SECONDS || 31 * 24 * 60 * 60));\n"
        if anchor not in text:
            raise RuntimeError("archive ranges constant anchor was not found")
        text = text.replace(anchor, CONSTANT + anchor, 1)
        changed = True

    if NEW_ROUTE not in text:
        count = text.count(OLD_ROUTE)
        if count != 1:
            raise RuntimeError(f"archive playback route anchor count={count}")
        text = text.replace(OLD_ROUTE, NEW_ROUTE, 1)
        changed = True

    if text.count(CONSTANT) != 1:
        raise RuntimeError(f"unexpected archive playback constant count: {text.count(CONSTANT)}")
    if text.count("parseRange(req, res, maxArchivePlaybackSeconds)") != 1:
        raise RuntimeError("archive playback route is not using the SmartYard-compatible limit")

    if changed:
        path.write_text(text, encoding="utf-8")
    return changed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-node")
    args = parser.parse_args()

    project = Path(args.project_dir).resolve()
    index = project / "dvr-engine" / "src" / "index.ts"
    if not index.is_file():
        raise SystemExit(f"DVR index source not found: {index}")

    changed = patch_index(index)
    print("SmartYard archive playback limit prepared" if changed else "SmartYard archive playback limit already prepared")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
