#!/usr/bin/env bash
set -Eeuo pipefail

# Split the current NewDomofon Video monorepository into two independent
# Git repositories while preserving history for the retained paths.
#
# Usage:
#   bash scripts/split-independent-repositories.sh /opt/newdomofon-video-split
#
# Optional:
#   REF=architecture/split-master-node-projects \
#   MASTER_REMOTE=git@github.com:owner/newdomofon-video-master.git \
#   NODE_REMOTE=git@github.com:owner/newdomofon-video-node.git \
#   PUSH=1 FORCE=1 \
#   bash scripts/split-independent-repositories.sh /opt/newdomofon-video-split

OUTPUT_ROOT="${1:-}"
REF="${REF:-HEAD}"
FORCE="${FORCE:-0}"
PUSH="${PUSH:-0}"
MASTER_REMOTE="${MASTER_REMOTE:-}"
NODE_REMOTE="${NODE_REMOTE:-}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

[[ -n "$OUTPUT_ROOT" ]] || fail "output directory is required"
need_command git
need_command git-filter-repo
need_command rsync

SOURCE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "run inside a Git working tree"
SOURCE_SHA="$(git -C "$SOURCE_ROOT" rev-parse "$REF")" || fail "cannot resolve REF=$REF"
SOURCE_BRANCH="$(git -C "$SOURCE_ROOT" symbolic-ref --quiet --short HEAD || true)"
SOURCE_REPOSITORY="$(git -C "$SOURCE_ROOT" remote get-url origin 2>/dev/null || echo local-working-copy)"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

MASTER_DIR="$OUTPUT_ROOT/newdomofon-video-master"
NODE_DIR="$OUTPUT_ROOT/newdomofon-video-node"
MASTER_PATHS="$SOURCE_ROOT/split/master-paths.txt"
NODE_PATHS="$SOURCE_ROOT/split/node-paths.txt"
MASTER_README="$SOURCE_ROOT/split/master-README.md"
NODE_README="$SOURCE_ROOT/split/node-README.md"

for file in "$MASTER_PATHS" "$NODE_PATHS" "$MASTER_README" "$NODE_README"; do
  [[ -f "$file" ]] || fail "required split file not found: $file"
done

prepare_output_root() {
  mkdir -p "$OUTPUT_ROOT"
  for dir in "$MASTER_DIR" "$NODE_DIR"; do
    if [[ -e "$dir" ]]; then
      if [[ "$FORCE" == "1" ]]; then
        echo "Removing existing output: $dir"
        rm -rf -- "$dir"
      else
        fail "$dir already exists; use FORCE=1 to replace it"
      fi
    fi
  done
}

configure_commit_identity() {
  local repo="$1"
  if ! git -C "$repo" config user.name >/dev/null; then
    git -C "$repo" config user.name "${GIT_AUTHOR_NAME:-NewDomofon Split Tool}"
  fi
  if ! git -C "$repo" config user.email >/dev/null; then
    git -C "$repo" config user.email "${GIT_AUTHOR_EMAIL:-split-tool@newdomofon.local}"
  fi
}

write_origin_note() {
  local repo="$1"
  local project="$2"

  cat >"$repo/SPLIT_ORIGIN.md" <<EOF
# Split origin

This repository was generated from the NewDomofon Video monorepository.

- Project: $project
- Source: $SOURCE_REPOSITORY
- Source ref: $REF
- Source commit: $SOURCE_SHA
- Source branch at generation time: ${SOURCE_BRANCH:-detached}
- Generated at: $GENERATED_AT

The master/node integration contract is stored in:

\`contracts/node-agent-api-v1.md\`
EOF
}

prune_master_files() {
  local repo="$1"

  rm -f -- \
    "$repo/deploy/env/node.env.example" \
    "$repo/deploy/nginx/newdomofon-video-node.conf" \
    "$repo/deploy/systemd/newdomofon-video-dvr.service" \
    "$repo/scripts/deploy-node.sh"

  # Runtime data and generated artifacts must never enter the new repository.
  rm -rf -- \
    "$repo/backups" \
    "$repo/node_modules" \
    "$repo/backend/node_modules" \
    "$repo/frontend/node_modules" \
    "$repo/frontend/dist"
}

prune_node_files() {
  local repo="$1"

  rm -f -- \
    "$repo/deploy/env/master.env.example" \
    "$repo/deploy/nginx/newdomofon-video.conf" \
    "$repo/deploy/systemd/newdomofon-video-backend.service" \
    "$repo/scripts/deploy-master.sh"

  rm -rf -- \
    "$repo/backups" \
    "$repo/node_modules" \
    "$repo/dvr-engine/node_modules" \
    "$repo/dvr-engine/dist"
}

split_repository() {
  local project="$1"
  local destination="$2"
  local paths_file="$3"
  local readme_template="$4"
  local remote_url="$5"

  echo
  echo "===== Creating $project ====="
  echo "source commit: $SOURCE_SHA"
  echo "destination:   $destination"

  # --no-local avoids hardlinks and gives git-filter-repo an isolated clone.
  git clone --no-local "$SOURCE_ROOT" "$destination"

  # Keep exactly the selected source revision as the future main branch.
  git -C "$destination" checkout --detach "$SOURCE_SHA"
  git -C "$destination" branch -f main "$SOURCE_SHA"
  git -C "$destination" checkout main

  # Remove unrelated branches/tags before filtering so each result contains
  # only the release line being split.
  while read -r ref; do
    [[ "$ref" == "refs/heads/main" ]] && continue
    git -C "$destination" update-ref -d "$ref" || true
  done < <(git -C "$destination" for-each-ref --format='%(refname)' refs/heads refs/remotes refs/tags)

  (
    cd "$destination"
    git filter-repo --force --paths-from-file "$paths_file"
  )

  git -C "$destination" branch -M main
  git -C "$destination" remote remove origin >/dev/null 2>&1 || true

  cp "$readme_template" "$destination/README.md"
  write_origin_note "$destination" "$project"

  case "$project" in
    master) prune_master_files "$destination" ;;
    node) prune_node_files "$destination" ;;
    *) fail "unknown project type: $project" ;;
  esac

  configure_commit_identity "$destination"
  git -C "$destination" add -A
  if ! git -C "$destination" diff --cached --quiet; then
    git -C "$destination" commit -m "Finalize independent $project repository"
  fi

  if [[ -n "$remote_url" ]]; then
    git -C "$destination" remote add origin "$remote_url"
  fi

  if [[ "$PUSH" == "1" ]]; then
    [[ -n "$remote_url" ]] || fail "PUSH=1 requires a remote URL for $project"
    git -C "$destination" push -u origin main
  fi

  echo "Created $destination"
  echo "HEAD: $(git -C "$destination" rev-parse HEAD)"
  echo "Files: $(git -C "$destination" ls-files | wc -l)"
}

verify_no_cross_source_dependencies() {
  local master="$1"
  local node="$2"
  local failed=0

  echo
  echo "===== Verifying repository boundaries ====="

  for forbidden in dvr-engine dvr-archive-proxy restreamer restream-gateway live-only-engine; do
    if [[ -e "$master/$forbidden" ]]; then
      echo "Unexpected node path in master: $forbidden" >&2
      failed=1
    fi
  done

  for forbidden in backend frontend public-events-proxy media-public-proxy smartyard-compat-proxy archive-policy-api; do
    if [[ -e "$node/$forbidden" ]]; then
      echo "Unexpected master path in node: $forbidden" >&2
      failed=1
    fi
  done

  [[ -f "$master/contracts/node-agent-api-v1.md" ]] || {
    echo "Master contract missing" >&2
    failed=1
  }
  [[ -f "$node/contracts/node-agent-api-v1.md" ]] || {
    echo "Node contract missing" >&2
    failed=1
  }

  if [[ "$failed" -ne 0 ]]; then
    fail "repository boundary verification failed"
  fi

  echo "Boundary verification passed"
}

print_next_steps() {
  cat <<EOF

===== Split complete =====

Master repository:
  $MASTER_DIR

Node repository:
  $NODE_DIR

Recommended next steps:

1. Create two empty GitHub repositories:
   rirodevdom/newdomofon-video-master
   rirodevdom/newdomofon-video-node

2. Add remotes and push, unless MASTER_REMOTE/NODE_REMOTE and PUSH=1 were used:

   git -C '$MASTER_DIR' remote add origin git@github.com:rirodevdom/newdomofon-video-master.git
   git -C '$MASTER_DIR' push -u origin main

   git -C '$NODE_DIR' remote add origin git@github.com:rirodevdom/newdomofon-video-node.git
   git -C '$NODE_DIR' push -u origin main

3. Do not change the production servers yet. First build both repositories and
   complete the compatibility checks from docs/REPOSITORY_SPLIT.md.

Source monorepository was not modified by this script.
EOF
}

prepare_output_root
split_repository master "$MASTER_DIR" "$MASTER_PATHS" "$MASTER_README" "$MASTER_REMOTE"
split_repository node "$NODE_DIR" "$NODE_PATHS" "$NODE_README" "$NODE_REMOTE"
verify_no_cross_source_dependencies "$MASTER_DIR" "$NODE_DIR"
print_next_steps
