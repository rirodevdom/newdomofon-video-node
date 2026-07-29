#!/usr/bin/env python3
from __future__ import annotations

import os
import shutil
from pathlib import Path

PROJECT_DIR = Path(os.environ.get("PROJECT_DIR", Path(__file__).resolve().parents[1])).resolve()
ENV_FILE = Path(os.environ.get("ENV_FILE", "/etc/newdomofon-video/app.env"))

REMOVED_PREFIXES = (
    "DVR_HIKVISION_",
    "DVR_DEVICE_ARCHIVE_",
)
REMOVED_EXACT = {
    "DVR_EVENT_STORE_RAW_PAYLOAD_HIKVISION",
}
LEGACY_DIST_FILES = (
    "hikvisionEvents.js",
    "hikvisionEvents.js.map",
    "hikvisionArchive.js",
    "hikvisionArchive.js.map",
    "deviceArchive.js",
    "deviceArchive.js.map",
    "deviceArchiveIndexer.js",
    "deviceArchiveIndexer.js.map",
)


def clean_env(path: Path) -> None:
    if not path.is_file():
        return
    original = path.read_text(encoding="utf-8").splitlines()
    kept: list[str] = []
    removed: list[str] = []
    for line in original:
        stripped = line.strip()
        key = stripped.split("=", 1)[0].strip() if "=" in stripped else ""
        if key in REMOVED_EXACT or any(key.startswith(prefix) for prefix in REMOVED_PREFIXES):
            removed.append(key)
            continue
        kept.append(line)
    if removed:
        path.write_text("\n".join(kept).rstrip() + "\n", encoding="utf-8")
        print(f"Removed obsolete Hikvision env keys from {path}: {', '.join(sorted(set(removed)))}")


def clean_dist() -> None:
    dist = PROJECT_DIR / "dvr-engine" / "dist"
    for name in LEGACY_DIST_FILES:
        target = dist / name
        if target.exists():
            target.unlink()
            print(f"Removed legacy compiled module: {target}")


def clean_temp() -> None:
    for target in (
        Path("/tmp/newdomofon-video-device-archive"),
        Path("/var/cache/newdomofon-video/device-archive"),
    ):
        if target.exists():
            shutil.rmtree(target, ignore_errors=True)
            print(f"Removed legacy device archive cache: {target}")


def main() -> int:
    clean_env(ENV_FILE)
    clean_dist()
    clean_temp()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
