#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat >&2 <<'EOF'
Usage: scripts/prettier-check-staged.sh FILE...

Runs prettier --check over the given files, skipping symlinks (prettier
refuses an explicitly named symlink, and .pi/mcp.json is one by design).
EOF
}

if [[ $# -eq 0 ]]; then
	usage
	exit 2
fi

files=()
for f in "$@"; do
	if [[ ! -L "$f" ]]; then
		files+=("$f")
	fi
done

if [[ ${#files[@]} -eq 0 ]]; then
	exit 0
fi

exec mise exec prettier -- prettier --check --ignore-unknown -- "${files[@]}"
