#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tool="$root/tools/pspice-com-fix.sh"
manifest="$root/bottles-programs/Software/orcadx.yml"

if grep -q "'" "$tool"; then
	echo "$tool must not contain single quotes." >&2
	exit 1
fi

updated=$(awk -v tool="$tool" '
	/<<"PSPICE_COM_FIX"$/ {
		print
		indent = $0
		sub(/[^ ].*/, "", indent)
		while ((getline line < tool) > 0)
			if (!(n++ == 0 && line ~ /^#!/)) print (line == "" ? "" : indent line)
		skip = 1
		next
	}
	skip && /^ *PSPICE_COM_FIX$/ { skip = 0 }
	!skip
' "$manifest")

if [[ ${1:-} == --check ]]; then
	if [[ $updated != "$(cat "$manifest")" ]]; then
		echo "$manifest is out of date: run tools/sync-installer-manifest.sh" >&2
		exit 1
	fi
	exit 0
fi
printf '%s\n' "$updated" >"$manifest"
