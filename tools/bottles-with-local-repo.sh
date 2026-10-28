#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../bottles-programs" && pwd)"

if pgrep -f '/bin/bottles( |$)' >/dev/null 2>&1; then
	echo "Bottles is running. Close it first, then run this script again." >&2
	exit 1
fi

echo "Installers repository: file://$repo_dir"
if command -v flatpak >/dev/null 2>&1 && flatpak info com.usebottles.bottles >/dev/null 2>&1; then
	exec flatpak run --filesystem="$repo_dir":ro \
		--env=PERSONAL_INSTALLERS="file://$repo_dir" com.usebottles.bottles "$@"
fi
PERSONAL_INSTALLERS="file://$repo_dir" exec bottles "$@"
