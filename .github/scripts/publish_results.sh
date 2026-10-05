#!/usr/bin/env bash
# Copy CI result files to the ci-results branch so they can be read without a login.
# usage: publish_results.sh <folder-name> <file>...
set -u
name="$1"; shift
tmp=$(mktemp -d)
for f in "$@"; do [ -f "$f" ] && cp "$f" "$tmp/"; done
echo "run: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID  sha: $GITHUB_SHA  status: ${JOB_STATUS:-?}" > "$tmp/RUN.txt"
git config user.name "lexi-bot"; git config user.email "lexi-bot@users.noreply.github.com"
for attempt in 1 2 3; do
  rm -rf ci && git clone -q --depth 1 --branch ci-results "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}" ci 2>/dev/null \
    || { rm -rf ci; mkdir ci; git -C ci init -q -b ci-results; git -C ci remote add origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}"; }
  rm -rf "ci/$name"; mkdir -p "ci/$name"; cp "$tmp"/* "ci/$name/"
  git -C ci add -A && git -C ci -c user.name=lexi-bot -c user.email=lexi-bot@users.noreply.github.com commit -qm "results: $name $GITHUB_RUN_ID" || exit 0
  git -C ci push -q origin ci-results && exit 0
  sleep 5
done
