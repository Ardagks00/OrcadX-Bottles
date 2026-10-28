#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly FLATPAK_ID="com.usebottles.bottles"
readonly MIN_FREE_GB=60
readonly SETUP_DIR_NAME="OrCADX-Setup"
readonly PSPICE_FIX="$SCRIPT_DIR/tools/pspice-com-fix.sh"
readonly FONT_ICON_FIX="$SCRIPT_DIR/tools/font-icon-fix.sh"

bottle_name="OrCAD-X"
installer=""
runner=""
recipe="$SCRIPT_DIR/recipe/orcad-x.yml"
extra_deps=""
language="en_US"
mode=""
skip_install=0
assume_yes=0

bottles_cli=()
bottles_path=""
runners_path=""
templates_path=""
stage_dir=""
bottle_dir=""
drive_c=""
installer_is_media=0

if [[ -t 1 ]]; then
	c_bold=$'\e[1m' c_red=$'\e[31m' c_yellow=$'\e[33m' c_blue=$'\e[34m' c_green=$'\e[32m' c_reset=$'\e[0m'
else
	c_bold="" c_red="" c_yellow="" c_blue="" c_green="" c_reset=""
fi

lowercase() {
	local LC_ALL=C
	printf '%s\n' "${1,,}"
}

step() { printf '\n%s==>%s %s%s%s\n' "$c_blue" "$c_reset" "$c_bold" "$*" "$c_reset"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%sWarning:%s %s\n' "$c_yellow" "$c_reset" "$*" >&2; }
die_called=0
die() {
	printf '%sError:%s %s\n' "$c_red" "$c_reset" "$*" >&2
	die_called=1
	exit 1
}

on_exit() {
	local rc=$?
	((rc == 0 || die_called)) && return
	if ((rc == 130)); then
		printf '\n%sInterrupted.%s Run the script again to continue where it stopped.\n' "$c_yellow" "$c_reset" >&2
	else
		printf '%sError:%s the script stopped unexpectedly (exit code %s).\n' "$c_red" "$c_reset" "$rc" >&2
	fi
}
trap on_exit EXIT

usage() {
	cat <<EOF
Usage: ${0##*/} [options]

Creates a Bottles bottle prepared for Cadence OrCAD X and runs the OrCAD X
installer inside it. Running the script again with the same bottle name skips
the steps that are already done.

Options:
  -i, --installer PATH   OrCAD X installer: OrCADXInstall.exe from Cadence, or
                         setup.exe of an extracted offline package. Searched in
                         the Downloads folder when omitted.
  -n, --name NAME        Bottle name (default: $bottle_name)
  -r, --runner NAME      Wine runner, e.g. soda-11.0-10 (default: newest Soda)
      --extra-deps LIST  Extra Bottles dependencies, comma separated,
                         e.g. gdiplus,d3dcompiler_47,webview2
      --recipe PATH      Environment recipe (default: recipe/orcad-x.yml)
      --language LOCALE  Windows regional settings of the bottle (default:
                         en_US, which uses '.' as decimal separator like the
                         Cadence tools expect); 'sys' keeps the desktop locale
      --no-install       Only create and configure the bottle
      --native           Use a natively installed bottles-cli, not the Flatpak
  -y, --yes              Answer yes to every question
  -h, --help             Show this help and exit
  -V, --version          Show the script version and exit
EOF
}

parse_args() {
	while (($#)); do
		case $1 in
		-i | --installer)
			installer=${2:?"$1 needs a path"}
			shift
			;;
		-n | --name)
			bottle_name=${2:?"$1 needs a name"}
			shift
			;;
		-r | --runner)
			runner=${2:?"$1 needs a runner name"}
			shift
			;;
		--extra-deps)
			extra_deps=${2:?"$1 needs a list"}
			shift
			;;
		--recipe)
			recipe=${2:?"$1 needs a path"}
			shift
			;;
		--language)
			language=${2:?"$1 needs a locale such as en_US or sys"}
			shift
			;;
		--no-install) skip_install=1 ;;
		--native) mode=native ;;
		-y | --yes) assume_yes=1 ;;
		-h | --help)
			usage
			exit 0
			;;
		-V | --version)
			echo "install-orcad-x.sh $SCRIPT_VERSION"
			exit 0
			;;
		*) die "Unknown option: $1 (see --help)" ;;
		esac
		shift
	done

	((EUID != 0)) || die "Run this script as your normal user, not as root or with sudo."
	[[ $bottle_name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
		die "Bottle name may only contain letters, digits, '.', '_' and '-'."
	[[ -z $extra_deps || $extra_deps =~ ^[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*$ ]] ||
		die "--extra-deps must be a comma separated list of dependency names."
	[[ $language == sys || $language =~ ^[a-z]{2,3}_[A-Z]{2}(\.(UTF-8|utf8))?$ ]] ||
		die "--language must look like en_US, de_DE.UTF-8 or be 'sys'."
	[[ -f $recipe ]] || die "Recipe not found: $recipe"
}

confirm() {
	((assume_yes)) && return 0
	[[ -t 0 ]] || return 1
	local reply
	read -r -p "$1 [y/N] " reply
	[[ $reply =~ ^([Yy]|[Yy][Ee][Ss]|[Ee]|[Ee][Vv][Ee][Tt])$ ]]
}

bcli() { "${bottles_cli[@]}" "$@"; }

detect_bottles() {
	step "Looking for Bottles"
	if [[ $mode != native ]] && command -v flatpak >/dev/null 2>&1 &&
		flatpak info "$FLATPAK_ID" >/dev/null 2>&1; then
		mode=flatpak
		bottles_cli=(flatpak run --command=bottles-cli "$FLATPAK_ID")
		stage_dir="$HOME/.var/app/$FLATPAK_ID/cache/orcad-x-bottles"
	elif command -v bottles-cli >/dev/null 2>&1; then
		mode=native
		bottles_cli=(bottles-cli)
		stage_dir="${XDG_CACHE_HOME:-$HOME/.cache}/orcad-x-bottles"
	else
		die "Bottles was not found. Install it with: flatpak install flathub $FLATPAK_ID"
	fi

	local version new_help
	version=$(bcli --version 2>/dev/null) || die "bottles-cli does not start."
	new_help=$(bcli new --help 2>/dev/null) || true
	[[ $new_help == *--custom-environment* ]] ||
		die "$version is too old: bottles-cli has no --custom-environment option."

	bottles_path=$(bcli info bottles-path 2>/dev/null) || true
	[[ -d $bottles_path ]] || die "Could not read the Bottles data directory (got '$bottles_path')."
	runners_path="$(dirname -- "$bottles_path")/runners"
	templates_path="$(dirname -- "$bottles_path")/templates"
	bottle_dir="$bottles_path/$bottle_name"
	drive_c="$bottle_dir/drive_c"
	mkdir -p -- "$stage_dir"

	if [[ -n $runner && $runner != sys-* && ! -d $runners_path/$runner ]]; then
		die "Runner '$runner' is not installed. Install it in Bottles (Preferences > Runners) first."
	fi

	info "$version ($mode)"
	info "Bottles directory: $bottles_path"
}

find_installer() {
	((skip_install)) && return 0

	if [[ -z $installer ]]; then
		local dir file
		local -A seen=()
		local found=()
		for dir in "$(xdg-user-dir DOWNLOAD 2>/dev/null || true)" "$HOME/Downloads" "$PWD"; do
			[[ -n $dir && -d $dir ]] || continue
			while IFS= read -r -d '' file; do
				file=$(realpath -- "$file")
				[[ -n ${seen[$file]:-} ]] && continue
				seen[$file]=1
				found+=("$file")
			done < <(find "$dir" -maxdepth 1 -type f -iname 'OrCADXInstall*.exe' -print0 2>/dev/null)
		done
		case ${#found[@]} in
		0) die "OrCADXInstall.exe was not found. Download it from Cadence and pass it with --installer PATH (or use --no-install)." ;;
		1) installer=${found[0]} ;;
		*) die "Several installers found, pick one with --installer: ${found[*]}" ;;
		esac
	fi

	[[ -f $installer ]] || die "Installer not found: $installer"
	installer=$(realpath -- "$installer")
	case $(lowercase "$installer") in
	*.exe)
		[[ $(head -c 2 -- "$installer") == MZ ]] || die "Not a Windows executable: $installer"
		;;
	*.msi) ;;
	*) die "The installer must be an .exe or .msi file: $installer" ;;
	esac

	local media_dir
	media_dir=$(dirname -- "$installer")
	if [[ -e $media_dir/setup.ini || -e $media_dir/Disk1 || -e $media_dir/data1.hdr ]] ||
		compgen -G "$media_dir/*.cab" >/dev/null || compgen -G "$media_dir/*.msi" >/dev/null; then
		installer_is_media=1
	fi
	info "Installer: $installer"
}

check_disk_space() {
	local avail_kb avail_gb need_gb=$MIN_FREE_GB
	((skip_install)) && need_gb=10
	avail_kb=$(df -Pk -- "$bottles_path" | awk 'NR == 2 { print $4 }')
	avail_gb=$((avail_kb / 1024 / 1024))
	if ((avail_gb < need_gb)); then
		warn "Only $avail_gb GB free on the Bottles drive; OrCAD X needs about 50 GB plus ~5 GB for the Windows runtimes."
		confirm "Continue anyway?" || die "Aborted: not enough free disk space."
	fi
}

stage_recipe() {
	local staged="$stage_dir/recipe.yml"
	awk -v deps="$extra_deps" '
		function flush(   i) {
			if (inlist && !done) {
				for (i = 1; i <= n; i++) print "  - " d[i]
				done = 1
			}
			inlist = 0
		}
		BEGIN { n = (deps == "") ? 0 : split(deps, d, ",") }
		/^Installed_Dependencies:/ { print; inlist = 1; next }
		inlist && /^[[:space:]]*(-|#|$)/ { print; next }
		inlist { flush() }
		{ print }
		END { flush() }
	' "$recipe" >"$staged"
	printf '%s' "$staged"
}

recipe_dependencies() {
	awk '
		/^Installed_Dependencies:/ { inlist = 1; next }
		inlist && /^[[:space:]]*-/ { sub(/^[[:space:]]*-[[:space:]]*/, ""); sub(/[[:space:]]*(#.*)?$/, ""); print; next }
		inlist && /^[[:space:]]*(#|$)/ { next }
		inlist { inlist = 0 }
	' "$1"
}

create_bottle() {
	step "Creating bottle '$bottle_name'"
	local staged
	staged=$(stage_recipe)

	if [[ -f $bottle_dir/bottle.yml ]]; then
		info "The bottle already exists, creation is skipped."
		local dep missing=()
		while IFS= read -r dep; do
			grep -Eq "^[[:space:]]*-[[:space:]]+${dep//./\\.}[[:space:]]*$" "$bottle_dir/bottle.yml" ||
				missing+=("$dep")
		done < <(recipe_dependencies "$staged")
		if ((${#missing[@]})); then
			warn "Dependencies missing in the existing bottle: ${missing[*]}"
			warn "Install them in Bottles (bottle > Dependencies) or use a new --name."
		fi
		return 0
	fi

	if [[ -e $bottle_dir ]]; then
		warn "$bottle_dir exists but contains no bottle.yml (an interrupted earlier attempt?)."
		confirm "Delete this folder and create the bottle again?" ||
			die "Aborted. Remove the folder or choose another --name."
		rm -rf -- "$bottle_dir"
	fi

	info "Downloading and installing .NET Framework 4.8, VC++ 2015-2022, fonts..."
	info "This usually takes 10-30 minutes. Bottles prints its progress below."
	local marker="$stage_dir/.creation-started"
	touch -- "$marker"

	local args=(new --bottle-name "$bottle_name" --environment custom
		--custom-environment "$staged" --arch win64)
	[[ -n $runner ]] && args+=(--runner "$runner")
	bcli "${args[@]}" || die "Bottles could not create the bottle. Fix the error above and run the script again."
	[[ -f $bottle_dir/bottle.yml ]] ||
		die "Bottles finished but $bottle_dir/bottle.yml is missing."

	local tpl
	while IFS= read -r -d '' tpl; do
		if grep -q '^env: custom$' "$tpl/template.yml" 2>/dev/null; then
			rm -rf -- "$tpl"
			info "Removed the unused custom template cache ($(basename -- "$tpl"))."
		fi
	done < <(find "$templates_path" -mindepth 1 -maxdepth 1 -type d -newer "$marker" -print0 2>/dev/null)
	rm -f -- "$marker"
}

reg_add() { bcli reg add -b "$bottle_name" -k "$1" -v "$2" -t "$3" -d "$4" >/dev/null; }

configure_bottle() {
	step "Configuring the bottle"
	info "Windows version: Windows 10"
	info "(the first Wine start of a new bottle can take long while Wine sets up the GPU)"
	bcli edit -b "$bottle_name" --win win10 >/dev/null

	if [[ $language != sys ]]; then
		local locale=$language
		[[ $locale == *.* ]] || locale="$locale.UTF-8"
		info "Regional settings: $locale (bottle environment variable LC_ALL)"
		bcli edit -b "$bottle_name" --env-var "LC_ALL=$locale" >/dev/null
	fi

	local owner=${USER:-$(id -un)}
	info "Registered owner: $owner"
	reg_add 'HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion' RegisteredOwner REG_SZ "$owner"
	reg_add 'HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\Windows NT\CurrentVersion' RegisteredOwner REG_SZ "$owner"

	info "WPF: software rendering"
	reg_add 'HKEY_CURRENT_USER\Software\Microsoft\Avalon.Graphics' DisableHWAcceleration REG_DWORD 1

	info "Disabling winemenubuilder (Bottles manages menu entries itself)"
	reg_add 'HKEY_CURRENT_USER\Software\Wine\DllOverrides' winemenubuilder.exe REG_SZ ''
	info "Font smoothing: subpixel RGB"
	reg_add 'HKEY_CURRENT_USER\Control Panel\Desktop' FontSmoothing REG_SZ 2
	reg_add 'HKEY_CURRENT_USER\Control Panel\Desktop' FontSmoothingType REG_DWORD 2
	reg_add 'HKEY_CURRENT_USER\Control Panel\Desktop' FontSmoothingGamma REG_DWORD 1400
	reg_add 'HKEY_CURRENT_USER\Control Panel\Desktop' FontSmoothingOrientation REG_DWORD 1
}

find_capture() {
	{ find "$drive_c" -maxdepth 6 -type f -ipath '*/tools/bin/capture.exe' 2>/dev/null || true; } |
		sort -V | tail -n 1
}

bottle_busy_processes() {
	local proc exe LC_ALL=C
	for proc in /proc/[0-9]*; do
		{ IFS= read -r -d '' exe <"$proc/cmdline"; } 2>/dev/null || continue
		exe=${exe##*[\\/]}
		exe=${exe,,}
		[[ $exe == *.exe || $exe == *.tmp ]] || continue
		case $exe in
		services.exe | winedevice.exe | svchost.exe | plugplay.exe | explorer.exe | rpcss.exe | \
			tabtip.exe | conhost.exe | start.exe | msiexec.exe | mscorsvw.exe | ngen*.exe | \
			cdsnameserver.exe | cdsmsgserver.exe | cmd.exe | node.exe) continue ;;
		esac
		{ tr '\0' '\n' <"$proc/environ" | grep -qxF "WINEPREFIX=$bottle_dir"; } 2>/dev/null || continue
		printf '%s\n' "$exe"
	done | sort -u | paste -sd ' ' -
}

wait_for_installer() {
	local busy previous="" idle=0
	while ((idle < 2)); do
		sleep 3
		busy=$(bottle_busy_processes)
		if [[ -z $busy ]]; then
			idle=$((idle + 1))
			continue
		fi
		idle=0
		[[ $busy == "$previous" ]] || info "Still running: $busy"
		previous=$busy
	done
}

run_installer() {
	((skip_install)) && return 0
	step "Running the OrCAD X installer"

	if [[ -n $(find_capture) ]]; then
		info "OrCAD X is already installed in this bottle."
		confirm "Run the installer again (repair, update or add products)?" || return 0
		pspice_com_fix remove || warn "Running the installer with the PSpice fix in place."
	fi

	local run_cli=("${bottles_cli[@]}") exe media_link=""
	mkdir -p -- "$drive_c/$SETUP_DIR_NAME"
	if ((installer_is_media)); then
		local media_dir media_root
		media_dir=$(dirname -- "$installer")
		media_root=$media_dir
		[[ $(basename -- "$media_dir") =~ [0-9]of[0-9] ]] && media_root=$(dirname -- "$media_dir")
		media_link="$drive_c/$SETUP_DIR_NAME/media"
		ln -sfn -- "$media_root" "$media_link"
		exe="$media_link/${installer#"$media_root"/}"
		[[ $mode == flatpak ]] &&
			run_cli=(flatpak run --filesystem="$media_root":ro --command=bottles-cli "$FLATPAK_ID")
	else
		local base
		base=$(basename -- "$installer")
		exe="$drive_c/$SETUP_DIR_NAME/${base//[^A-Za-z0-9._-]/_}"
		[[ $installer -ef $exe ]] || cp -f -- "$installer" "$exe"
		info "Copied the installer to C:\\$SETUP_DIR_NAME (keep it for repair/uninstall)."
	fi

	cat <<EOF

    The installer window opens now. In the installer:
      1. Sign in with your Cadence account.
      2. Accept the license agreement.
      3. Keep the default installation directory (C:\\Cadence\\OrCADX_<version>)
         and working directory, then click Install.
      4. Wait until the download and installation are complete (~50 GB).
    This terminal waits until every installer process has exited. If the
    installer starts OrCAD at the end, close OrCAD to continue.

EOF
	"${run_cli[@]}" run -b "$bottle_name" -e "$exe" || warn "The installer exited with an error code."
	info "Waiting for the remaining installer processes..."
	wait_for_installer
	[[ -z $media_link ]] || rm -f -- "$media_link"
}

register_programs() {
	((skip_install)) && return 0
	step "Registering OrCAD X in Bottles"

	local capture
	capture=$(find_capture)
	if [[ -z $capture ]]; then
		warn "OrCAD X Capture was not found in the bottle, so nothing was registered."
		warn "If the installation was cancelled or failed, run this script again."
		return 0
	fi

	local rel="${capture#"$drive_c"/}"
	local win="C:\\${rel//\//\\}" programs
	info "Found: $win"
	programs=$(bcli --json programs -b "$bottle_name" 2>/dev/null) || true
	if [[ $programs == *'"name": "OrCAD X Capture"'* ]]; then
		info "OrCAD X Capture is already in the program list."
	else
		bcli add -b "$bottle_name" -n "OrCAD X Capture" -p "$win" >/dev/null
		info "Added 'OrCAD X Capture' to the program list."
	fi
	info "The other OrCAD X tools (PCB Editor, PSpice, ...) are picked up from the"
	info "Windows Start Menu entries automatically."
}

registry_tool() {
	local tool=$1 action=$2 busy
	[[ -f $tool ]] || {
		warn "$tool is missing; download the whole repository."
		return 1
	}
	busy=$(bottle_busy_processes)
	if [[ -n $busy ]]; then
		warn "Programs are running in the bottle: $busy"
		warn "Close OrCAD X, then run: $tool --bottle-dir '$bottle_dir' $action"
		return 1
	fi
	bottle_running && { bcli stop -b "$bottle_name" >/dev/null 2>&1 || true; }
	bash "$tool" --bottle-dir "$bottle_dir" --wait 60 "$action" | sed 's/^/    /'
}

pspice_com_fix() { registry_tool "$PSPICE_FIX" "$1"; }

bottle_running() {
	local proc
	for proc in /proc/[0-9]*; do
		{ tr '\0' '\n' <"$proc/environ" | grep -qxF "WINEPREFIX=$bottle_dir"; } 2>/dev/null && return 0
	done
	return 1
}

fix_pspice() {
	[[ -n $(find_capture) ]] || return 0
	step "Letting Capture start PSpice simulations"
	info "Replacing the OLE handler of the PSpice COM classes (Wine bug workaround):"
	pspice_com_fix apply ||
		warn "Not applied. PSpice simulations fail until it is (ORCOMMN-2302, ORCAP-15053)."
}

fix_fonts_and_icons() {
	[[ -n $(find_capture) ]] || return 0
	step "Fonts and icons"
	info "Selawik for Segoe UI, SVG icons of Capture and PSpice without Direct2D:"
	registry_tool "$FONT_ICON_FIX" apply ||
		warn "Not applied. The interface uses Times New Roman until it is."
	info "Undo with: $FONT_ICON_FIX --bottle-dir '$bottle_dir' remove"
}

summary() {
	step "${c_green}Done${c_reset}"
	info "Bottle:   $bottle_name ($bottle_dir)"
	if ((skip_install)); then
		info "Install OrCAD X later with:"
		info "  ${0##*/} --name $bottle_name --installer /path/to/OrCADXInstall.exe"
	else
		info "Start it from Bottles: $bottle_name > Programs > OrCAD X Capture"
		if [[ $mode == flatpak ]]; then
			info "or from a terminal:   flatpak run --command=bottles-cli $FLATPAK_ID run -b $bottle_name -p 'OrCAD X Capture'"
		else
			info "or from a terminal:   bottles-cli run -b $bottle_name -p 'OrCAD X Capture'"
		fi
	fi
	info "Restart Bottles if it was already open so it shows the new bottle."
}

main() {
	parse_args "$@"
	detect_bottles
	find_installer
	check_disk_space
	create_bottle
	configure_bottle
	run_installer
	register_programs
	fix_pspice
	fix_fonts_and_icons
	summary
}

main "$@"; exit
