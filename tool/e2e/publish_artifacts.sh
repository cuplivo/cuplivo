#!/usr/bin/env bash
# Publishes validated E2E screenshots/video to a per-PR orphan branch so the
# PR comment can embed them through raw.githubusercontent.com.
#
# The branch holds one commit with only the latest run for that PR; a force push
# replaces it, so storage stays bounded and old comments are refreshed by the
# sticky comment on the next run. The caller (the publish job) never checks out
# PR code before invoking this script on the /e2e path.
set -euo pipefail

SOURCE=""
BRANCH=""
SHA=""
REPO=""
TOKEN=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) SOURCE="${2:-}"; shift 2 ;;
    --branch) BRANCH="${2:-}"; shift 2 ;;
    --sha) SHA="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --token) TOKEN="${2:-}"; shift 2 ;;
    *) echo "publish_artifacts: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$SOURCE" ] || [ -z "$BRANCH" ] || [ -z "$SHA" ] || [ -z "$REPO" ] || [ -z "$TOKEN" ]; then
  echo "publish_artifacts: --source, --branch, --sha, --repo and --token are required" >&2
  exit 2
fi
if ! printf '%s' "$BRANCH" | grep -Eq '^e2e-artifacts-pr-[0-9]+$'; then
  echo "publish_artifacts: refusing unexpected branch name" >&2
  exit 2
fi
if ! printf '%s' "$SHA" | grep -Eq '^[0-9a-f]{7,64}$'; then
  echo "publish_artifacts: refusing unexpected commit sha" >&2
  exit 2
fi
if [ ! -d "$SOURCE" ]; then
  echo "publish_artifacts: source directory missing" >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DEST="$WORK/$SHA"
mkdir -p "$DEST/failures"

shopt -s nullglob
screenshots=("$SOURCE"/screenshots/*.png)
failures=("$SOURCE"/failure-screenshots/*.png)
videos=("$SOURCE"/video/*.mp4 "$SOURCE"/video/*.webm)
gifs=("$SOURCE"/video/*.gif)

count=0
for file in "${screenshots[@]}"; do
  cp "$file" "$DEST/"
  count=$((count + 1))
done
for file in "${failures[@]}"; do
  cp "$file" "$DEST/failures/"
  count=$((count + 1))
done
for file in "${videos[@]}"; do
  cp "$file" "$DEST/"
  count=$((count + 1))
done
for file in "${gifs[@]}"; do
  cp "$file" "$DEST/"
  count=$((count + 1))
done

if [ "$count" -eq 0 ]; then
  echo "publish_artifacts: no valid artifacts to publish"
  exit 0
fi

cd "$WORK"
git init -q
git checkout -q --orphan artifacts
git add -A
git -c user.name='github-actions[bot]' \
    -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit -q -m "e2e artifacts for $BRANCH ($SHA)"
if ! git push -q --force "https://x-access-token:${TOKEN}@github.com/${REPO}.git" \
    "HEAD:refs/heads/${BRANCH}"; then
  echo "publish_artifacts: push failed" >&2
  exit 1
fi
echo "publish_artifacts: published $count file(s) to $BRANCH"
