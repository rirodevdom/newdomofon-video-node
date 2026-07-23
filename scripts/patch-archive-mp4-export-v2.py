#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

IMPORT = "import { registerArchiveMp4ExportV2Route } from './archiveMp4ExportV2.js';\n"
IMPORT_ANCHOR = "import { registerArchiveExportRoute } from './archiveExport.js';\n"
CALL = "registerArchiveMp4ExportV2Route(app);\n"
CALL_ANCHOR = "registerArchiveExportRoute(app);\n"


def patch_index(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    changed = False

    if IMPORT not in text:
        if text.count(IMPORT_ANCHOR) != 1:
            raise RuntimeError("legacy archive export import anchor was not found exactly once")
        text = text.replace(IMPORT_ANCHOR, IMPORT_ANCHOR + IMPORT, 1)
        changed = True

    if CALL not in text:
        if text.count(CALL_ANCHOR) != 1:
            raise RuntimeError("legacy archive export call anchor was not found exactly once")
        text = text.replace(CALL_ANCHOR, CALL + CALL_ANCHOR, 1)
        changed = True

    if text.count(IMPORT) != 1:
        raise RuntimeError(f"unexpected canonical export import count: {text.count(IMPORT)}")
    if text.count(CALL) != 1:
        raise RuntimeError(f"unexpected canonical export call count: {text.count(CALL)}")
    if text.index(CALL) > text.index(CALL_ANCHOR):
        raise RuntimeError("canonical export route must be registered before the legacy route")

    if changed:
        path.write_text(text, encoding="utf-8")
    return changed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-node")
    args = parser.parse_args()

    project = Path(args.project_dir).resolve()
    index = project / "dvr-engine" / "src" / "index.ts"
    exporter = project / "dvr-engine" / "src" / "archiveMp4ExportV2.ts"

    if not index.is_file():
        raise SystemExit(f"DVR index source not found: {index}")
    if not exporter.is_file():
        raise SystemExit(f"Canonical MP4 exporter source not found: {exporter}")

    changed = patch_index(index)
    print("Canonical MP4 export route prepared" if changed else "Canonical MP4 export route already prepared")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
