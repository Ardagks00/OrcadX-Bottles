#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=C

readonly FLATPAK_ID=com.usebottles.bottles
readonly BACKUP_NAME=font-icon-fix.backup

CHANGES=$(
	cat <<'EOF'
fonts	Software\\Wine\\Fonts\\Replacements	Segoe UI	"Selawik"
fonts	Software\\Wine\\Fonts\\Replacements	Segoe UI Bold	"Selawik"
fonts	Software\\Wine\\Fonts\\Replacements	Segoe UI Light	"Selawik Light"
fonts	Software\\Wine\\Fonts\\Replacements	Segoe UI Semibold	"Selawik Semibold"
fonts	Software\\Wine\\Fonts\\Replacements	Segoe UI Semilight	"Selawik Semilight"
icons	Software\\Wine\\AppDefaults\\Capture.exe\\DllOverrides	d2d1	""
icons	Software\\Wine\\AppDefaults\\pspice.exe\\DllOverrides	d2d1	""
EOF
)

usage() {
	cat <<EOF
Usage: ${0##*/} [options] [apply|remove|status]

Makes the OrCAD X interface look closer to Windows: Selawik instead of Times
New Roman for Segoe UI, and SVG icons drawn without Direct2D (README.md,
section "Fonts and icons"). The bottle must not be running for apply and
remove.

  -n, --name NAME        Bottle name (default: OrCAD-X)
  -d, --bottle-dir DIR   Bottle directory, for bottles outside the default path
  -o, --only PART        Only the fonts or only the icons part
  -w, --wait SECONDS     Wait up to SECONDS for the bottle to stop
  -s, --stop             Stop the bottle if it still runs after waiting
  apply                  Apply the fix (default)
  remove                 Restore the values from before the first apply
  status                 Show the current values
EOF
}

die() {
	printf 'Error: %s\n' "$*" >&2
	exit 1
}

REG_EDIT=$(
	cat <<'AWK'
function lc(s) { return tolower(s) }
function header_key(line) {
	sub(/^\[/, "", line)
	sub(/\] [0-9]+$/, "", line)
	sub(/\]$/, "", line)
	return lc(line)
}
function value_name(line,    name) {
	if (substr(line, 1, 1) != "\"") return ""
	name = substr(line, 2)
	sub(/"=.*/, "", name)
	return lc(name)
}
function print_blanks() { for (; blanks > 0; blanks--) print "" }
function print_header() {
	if (!held) return
	for (; held_blanks > 0; held_blanks--) print ""
	printf "%s", header
	held = 0
}
function finish_key(    i) {
	if (key == "") return
	for (i = 1; i <= n; i++)
		if (op[i] == "set" && okey[i] == key && !done[i]) {
			print_header()
			print "\"" oname[i] "\"=" odata[i]
			done[i] = 1
		}
	if (held) { blanks += held_blanks; held = 0 }
}
BEGIN { FS = "\t" }
FNR == NR {
	n++
	op[n] = $1; okey[n] = lc($2); orig_key[n] = $2; oname[n] = $3; odata[n] = $4
	touched[okey[n]] = 1
	next
}
mode == "get" {
	if (/^\[/) key = header_key($0)
	else if (key != "" && (name = value_name($0)) != "")
		for (i = 1; i <= n; i++)
			if (okey[i] == key && lc(oname[i]) == name) { current[i] = $0; sub(/^"[^"]*"=/, "", current[i]) }
	next
}
cont { cont = /\\$/; if (!skip) print; next }
/^\[/ {
	finish_key()
	key = header_key($0)
	if (key in touched) { held = 1; header = $0 "\n"; held_blanks = blanks; blanks = 0 }
	else { print_blanks(); print }
	next
}
$0 == "" { blanks++; next }
/^#/ && held { header = header $0 "\n"; next }
{
	skip = 0
	if (key != "" && (name = value_name($0)) != "") {
		for (i = 1; i <= n; i++) {
			if (okey[i] != key || lc(oname[i]) != name) continue
			if (op[i] == "set" && !done[i]) { print_header(); print_blanks(); print "\"" oname[i] "\"=" odata[i]; done[i] = 1 }
			skip = 1
		}
	}
	cont = /\\$/
	if (!skip) { print_header(); print_blanks(); print }
}
END {
	if (mode == "get") {
		for (i = 1; i <= n; i++) print orig_key[i] "\t" oname[i] "\t" (i in current ? current[i] : "-")
		exit
	}
	finish_key()
	for (i = 1; i <= n; i++) {
		if (op[i] != "set" || done[i]) continue
		print ""
		print "[" orig_key[i] "] " now
		print "#time=" sprintf("%x", (now + 11644473600) * 10000000)
		for (j = i; j <= n; j++)
			if (op[j] == "set" && okey[j] == okey[i] && !done[j]) {
				print "\"" oname[j] "\"=" odata[j]
				done[j] = 1
			}
	}
}
AWK
)

reg_edit() {
	local mode=$1 ops=$2
	awk -v mode="$mode" -v now="$(date +%s)" "$REG_EDIT" "$ops" "$reg"
}

selected_changes() {
	if [[ -z $only ]]; then
		printf '%s\n' "$CHANGES"
	else
		printf '%s\n' "$CHANGES" | awk -F '\t' -v part="$only" '$1 == part'
	fi
}

print_status() {
	local ops part key name want current state
	ops=$(mktemp)
	selected_changes | awk -F '\t' -v OFS='\t' '{ print "get", $2, $3, "" }' >"$ops"
	paste <(selected_changes) <(reg_edit get "$ops" | cut -f 3) |
		while IFS=$'\t' read -r part key name want current; do
			if [[ $current == "$want" ]]; then
				state=applied
			else
				state="not applied (now: $current)"
			fi
			printf '%-6s %-55s %-20s %s\n' "$part" "${key//\\\\/\\}" "$name" "$state"
		done
	rm -f -- "$ops"
}

bottle_processes() {
	local proc exe
	for proc in /proc/[0-9]*; do
		{ tr '\0' '\n' <"$proc/environ" | grep -qxF "WINEPREFIX=$bottle_dir"; } 2>/dev/null || continue
		{ IFS= read -r -d '' exe <"$proc/cmdline"; } 2>/dev/null || exe="?"
		printf '%s %s\n' "${proc#/proc/}" "${exe##*[\\/]}"
	done
}

wait_stopped() {
	local deadline=$((SECONDS + $1))
	while [[ -n $(bottle_processes) ]]; do
		((SECONDS < deadline)) || return 1
		sleep 1
	done
}

stop_bottle() {
	local pid name
	while read -r pid name; do
		[[ $name == wineserver ]] || continue
		WINEPREFIX=$bottle_dir "$(readlink "/proc/$pid/exe")" -k 2>/dev/null || true
		return
	done < <(bottle_processes)
}

bottle_name=OrCAD-X
bottle_dir=""
action=apply
only=""
wait=0
stop=0
while (($#)); do
	case $1 in
	-n | --name)
		[[ $# -ge 2 ]] || die "$1 needs a value."
		bottle_name=$2
		shift
		;;
	-d | --bottle-dir)
		[[ $# -ge 2 ]] || die "$1 needs a value."
		bottle_dir=$2
		shift
		;;
	-o | --only)
		[[ $# -ge 2 && $2 =~ ^(fonts|icons)$ ]] || die "$1 needs fonts or icons."
		only=$2
		shift
		;;
	-w | --wait)
		[[ $# -ge 2 && $2 =~ ^[0-9]+$ ]] || die "$1 needs a number of seconds."
		wait=$2
		shift
		;;
	-s | --stop) stop=1 ;;
	apply | remove | status) action=$1 ;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "Unknown argument: $1 (see --help)" ;;
	esac
	shift
done

if [[ -z $bottle_dir ]]; then
	for bottle_dir in \
		"$HOME/.var/app/$FLATPAK_ID/data/bottles/bottles/$bottle_name" \
		"${XDG_DATA_HOME:-$HOME/.local/share}/bottles/bottles/$bottle_name"; do
		[[ -f $bottle_dir/user.reg ]] && break
	done
fi
bottle_dir=${bottle_dir%/}
reg=$bottle_dir/user.reg
backup=$bottle_dir/$BACKUP_NAME
[[ -f $reg ]] || die "No bottle registry at $reg. Pass the bottle with --name or --bottle-dir."

if [[ $action == status ]]; then
	print_status
	exit 0
fi

if ! wait_stopped "$wait" && ! { ((stop)) && stop_bottle && wait_stopped 30; }; then
	die "The bottle is running: $(bottle_processes | cut -d ' ' -f 2 | sort -u | paste -sd ' ' -)
Close OrCAD X, then stop the bottle (Bottles: bottle menu > Force Stop all
Processes) and run this again."
fi

ops=$(mktemp)
tmp=$(mktemp "$reg.XXXXXX")
cleanup() { rm -f -- "$ops" "$tmp"; }
trap cleanup EXIT

if [[ $action == apply ]]; then
	selected_changes | awk -F '\t' -v OFS='\t' '{ print "get", $2, $3, "" }' >"$ops"
	touch -- "$backup"
	reg_edit get "$ops" | while IFS=$'\t' read -r key name data; do
		grep -qiF -- "$key"$'\t'"$name"$'\t' "$backup" || printf '%s\t%s\t%s\n' "$key" "$name" "$data" >>"$backup"
	done
	selected_changes | awk -F '\t' -v OFS='\t' '{ print "set", $2, $3, $4 }' >"$ops"
else
	[[ -s $backup ]] || die "Nothing to remove: $backup does not exist."
	selected_changes | cut -f 2,3 >"$tmp"
	awk -F '\t' -v OFS='\t' 'FNR == NR { want[tolower($1 "\t" $2)] = 1; next }
		tolower($1 "\t" $2) in want { print ($3 == "-" ? "del" : "set"), $1, $2, $3 }' "$tmp" "$backup" >"$ops"
fi

reg_edit edit "$ops" >"$tmp"
chmod --reference="$reg" -- "$tmp"
mv -f -- "$tmp" "$reg"

if [[ $action == remove ]]; then
	selected_changes | cut -f 2,3 >"$ops"
	awk -F '\t' 'FNR == NR { want[tolower($1 "\t" $2)] = 1; next }
		!(tolower($1 "\t" $2) in want)' "$ops" "$backup" >"$backup.tmp"
	mv -f -- "$backup.tmp" "$backup"
	[[ -s $backup ]] || rm -f -- "$backup"
fi

print_status
