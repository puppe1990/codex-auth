#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"

if [[ "$mode" != "--check" && "$mode" != "--staged-fix" ]]; then
  echo "Usage: scripts/check-zig.sh --check|--staged-fix" >&2
  exit 2
fi

cd "$(git rev-parse --show-toplevel)"

check_home="${CODEX_AUTH_CHECK_HOME:-/tmp/codex-auth-check}"
mkdir -p "$check_home"
export HOME="$check_home"

read_lines() {
  local line
  while IFS= read -r line; do
    files+=("$line")
  done
}

files=()
read_lines < <(git ls-files -- 'build.zig' '*.zig')
tracked_zig_files=("${files[@]}")

if [[ "${#tracked_zig_files[@]}" -eq 0 ]]; then
  echo "No Zig files found."
  exit 0
fi

if [[ "$mode" == "--check" ]]; then
  echo "Checking Zig formatting..."
  zig fmt --check "${tracked_zig_files[@]}"
else
  files=()
  read_lines < <(git diff --cached --name-only --diff-filter=ACMR -- 'build.zig' '*.zig')
  staged_zig_files=("${files[@]}")
  if [[ "${#staged_zig_files[@]}" -gt 0 ]]; then
    for file in "${staged_zig_files[@]}"; do
      if ! git diff --quiet -- "$file"; then
        echo "Refusing to auto-format $file because it has unstaged changes." >&2
        echo "Stage or stash the remaining edits first, then retry." >&2
        exit 1
      fi
    done
    echo "Formatting staged Zig files..."
    zig fmt "${staged_zig_files[@]}"
    git add -- "${staged_zig_files[@]}"
  else
    echo "No staged Zig files to format."
  fi
fi

echo "Running Zig tests..."
zig build test

echo "Running list validation..."
zig build run -- list
