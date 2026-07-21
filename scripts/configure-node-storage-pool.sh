#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
DRY_RUN=false
ALLOW_ROOT_FILESYSTEM=false
INTERACTIVE=false
ROOTS=()

usage() {
  cat <<'EOF'
Configure one or more mounted filesystems for NewDomofon archive recording.

The script never formats or mounts a disk. It only selects existing writable
mountpoints and stores their paths in DVR_STORAGE_ROOTS.

Usage:
  sudo bash scripts/configure-node-storage-pool.sh [options]

Options:
  --interactive             Show mounted filesystems and choose by number.
  --root PATH               Add one archive mountpoint. May be repeated.
  --roots PATH1,PATH2       Add comma-separated archive mountpoints.
  --env-file PATH           Runtime env file.
  --allow-root-filesystem   Permit paths that are not exact mountpoints.
  --dry-run                 Validate and print the resulting non-secret settings.
  -h, --help                Show this help.

Examples:
  sudo bash scripts/configure-node-storage-pool.sh --interactive

  sudo bash scripts/configure-node-storage-pool.sh \
    --root /srv/archive-a \
    --root /srv/archive-b
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --interactive) INTERACTIVE=true; shift ;;
    --root) ROOTS+=("${2:-}"); shift 2 ;;
    --roots)
      IFS=',' read -r -a supplied <<<"${2:-}"
      ROOTS+=("${supplied[@]}")
      shift 2
      ;;
    --env-file) ENV_FILE="${2:-}"; shift 2 ;;
    --allow-root-filesystem) ALLOW_ROOT_FILESYSTEM=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || fail "run as root"
[[ -f "$ENV_FILE" ]] || fail "environment file not found: $ENV_FILE"
for command in python3 findmnt df; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done

candidate_file="$(mktemp)"
cleanup() { rm -f "$candidate_file"; }
trap cleanup EXIT

list_candidates() {
  python3 - <<'PY'
import os
import subprocess

pseudo = {
    'autofs', 'binfmt_misc', 'bpf', 'cgroup', 'cgroup2', 'configfs', 'debugfs',
    'devpts', 'devtmpfs', 'efivarfs', 'fusectl', 'hugetlbfs', 'mqueue', 'overlay',
    'proc', 'pstore', 'ramfs', 'securityfs', 'squashfs', 'sysfs', 'tmpfs', 'tracefs'
}

result = subprocess.run(
    ['findmnt', '-rn', '-o', 'TARGET,SOURCE,FSTYPE,OPTIONS'],
    check=True,
    text=True,
    capture_output=True,
)
seen = set()
for raw in result.stdout.splitlines():
    parts = raw.split(None, 3)
    if len(parts) < 4:
        continue
    target, source, fstype, options = parts
    target = os.path.abspath(target)
    if target in seen or fstype in pseudo or 'ro' in options.split(','):
        continue
    if target in {'/', '/boot', '/boot/efi'}:
        continue
    seen.add(target)
    print('\t'.join([target, source, fstype]))
PY
}

list_candidates >"$candidate_file"

if [[ "$INTERACTIVE" == true || (${#ROOTS[@]} -eq 0 && -t 0) ]]; then
  mapfile -t candidates <"$candidate_file"
  ((${#candidates[@]} > 0)) || fail "no writable mounted data filesystems were found"

  echo "Available mounted filesystems:"
  for index in "${!candidates[@]}"; do
    IFS=$'\t' read -r target source fstype <<<"${candidates[$index]}"
    size="$(df -hP "$target" | awk 'NR==2 {print $2}')"
    available="$(df -hP "$target" | awk 'NR==2 {print $4}')"
    printf '  %d) %-28s device=%-18s fs=%-8s size=%-8s available=%s\n' \
      "$((index + 1))" "$target" "$source" "$fstype" "$size" "$available"
  done
  echo
  read -r -p "Select archive filesystems by number, comma separated: " selection
  [[ -n "$selection" ]] || fail "no filesystems selected"
  IFS=',' read -r -a numbers <<<"$selection"
  for raw in "${numbers[@]}"; do
    number="${raw//[[:space:]]/}"
    [[ "$number" =~ ^[0-9]+$ ]] || fail "invalid selection: $raw"
    ((number >= 1 && number <= ${#candidates[@]})) || fail "selection out of range: $number"
    IFS=$'\t' read -r target _ <<<"${candidates[$((number - 1))]}"
    ROOTS+=("$target")
  done
fi

((${#ROOTS[@]} > 0)) || fail "use --interactive, --root or --roots"

mapfile -t normalized_roots < <(
  printf '%s\n' "${ROOTS[@]}" |
  python3 -c '
import os, sys
seen = set()
for raw in sys.stdin:
    value = raw.strip()
    if not value:
        continue
    if not os.path.isabs(value):
        raise SystemExit(f"archive root must be absolute: {value}")
    value = os.path.abspath(value)
    if "," in value or "\n" in value or "\r" in value:
        raise SystemExit(f"archive root contains an unsupported character: {value}")
    if value not in seen:
        seen.add(value)
        print(value)
'
)

((${#normalized_roots[@]} > 0)) || fail "no valid archive roots selected"

declare -A devices=()
for root in "${normalized_roots[@]}"; do
  [[ -d "$root" ]] || fail "selected path does not exist: $root"
  [[ -w "$root" && -x "$root" ]] || fail "selected path is not writable: $root"

  if [[ "$ALLOW_ROOT_FILESYSTEM" != true ]] && ! mountpoint -q "$root"; then
    fail "$root is not an exact mountpoint; mount the disk there or use --allow-root-filesystem"
  fi

  source="$(findmnt -T "$root" -n -o SOURCE | head -1)"
  [[ -n "$source" ]] || fail "cannot determine backing device for $root"
  if [[ -n "${devices[$source]:-}" ]]; then
    fail "$root and ${devices[$source]} use the same backing filesystem $source"
  fi
  devices[$source]="$root"

  test_file="$root/.newdomofon-storage-write-test.$$"
  : >"$test_file"
  rm -f "$test_file"
done

joined="$(IFS=','; echo "${normalized_roots[*]}")"
require_mountpoint=true
[[ "$ALLOW_ROOT_FILESYSTEM" == true ]] && require_mountpoint=false

echo "Selected archive storage pool:"
for root in "${normalized_roots[@]}"; do
  findmnt -T "$root" -n -o TARGET,SOURCE,FSTYPE,OPTIONS
  df -hP "$root" | sed -n '1,2p'
done

echo
printf 'DVR_ROOT=%s\n' "${normalized_roots[0]}"
printf 'DVR_STORAGE_ROOTS=%s\n' "$joined"
printf 'DVR_DISK_REQUIRE_MOUNTPOINT=%s\n' "$require_mountpoint"

if [[ "$DRY_RUN" == true ]]; then
  echo "DRY RUN passed; no files were changed."
  exit 0
fi

backup="${ENV_FILE}.before-storage-pool-$(date +%Y%m%d-%H%M%S)"
cp -a "$ENV_FILE" "$backup"

python3 - "$ENV_FILE" "${normalized_roots[0]}" "$joined" "$require_mountpoint" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
updates = {
    'DVR_ROOT': sys.argv[2],
    'DVR_STORAGE_ROOTS': sys.argv[3],
    'DVR_DISK_REQUIRE_MOUNTPOINT': sys.argv[4],
}
lines = path.read_text(encoding='utf-8').splitlines()
out = []
seen = set()
for line in lines:
    key = line.split('=', 1)[0] if '=' in line else ''
    if key in updates:
        if key not in seen:
            out.append(f'{key}={updates[key]}')
            seen.add(key)
    else:
        out.append(line)
for key, value in updates.items():
    if key not in seen:
        out.append(f'{key}={value}')
path.write_text('\n'.join(out).rstrip('\n') + '\n', encoding='utf-8')
PY

chmod 0600 "$ENV_FILE" 2>/dev/null || true
systemctl restart newdomofon-video-node-disk-guard.service 2>/dev/null || true
systemctl restart newdomofon-video-dvr.service

for _ in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:3010/health >/tmp/newdomofon-storage-pool-health.json 2>/dev/null; then
    break
  fi
  sleep 1
done

python3 -m json.tool /tmp/newdomofon-storage-pool-health.json 2>/dev/null || true
echo "Storage pool configured. Backup: $backup"
