#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TARGET_USER=${SUDO_USER:-${USER}}
TARGET_HOME=${HOME}
DRY_RUN=0
DO_PACKAGES=0
DO_BUILD=0
DO_INSTALL_SUCKLESS=0
DO_DEPLOY_CONFIG=0
DO_DEPLOY_SESSION=0
DO_ENABLE_SERVICES=0
PROFILE=""

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --profile {work|laptop|pc}  Package/service profile to use
  --packages                  Install required packages
  --build                     Build suckless tools from this repo
  --install-suckless          Install suckless tools to the system
  --deploy-config             Deploy dotfiles, configs, wallpapers, scripts
  --deploy-session            Deploy session files and picom config
  --enable-services           Enable libvirt / laptop profile services
  --all                       Run packages, build, install, deploy, session, services
  --target-user USER          Override target user for config deployment
  --dry-run                   Print actions without executing them
  -h, --help                  Show this help

Examples:
  sudo ./start.sh --profile laptop --all
  ./start.sh --build
  sudo ./start.sh --deploy-config --deploy-session
EOF
}

log() {
	printf '[start.sh] %s\n' "$*"
}

die() {
	printf '[start.sh] ERROR: %s\n' "$*" >&2
	exit 1
}

run() {
	if [ "$DRY_RUN" -eq 1 ]; then
		printf '[dry-run] %s\n' "$*"
	else
		eval "$@"
	fi
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_root() {
	[ "$(id -u)" -eq 0 ] || die "This action must be run as root."
}

set_target_user() {
	local user=$1
	TARGET_USER=$user
	TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)
	[ -n "$TARGET_HOME" ] || die "Could not resolve home directory for user $TARGET_USER"
}

run_as_target_user() {
	local cmd=$1
	if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
		run "sudo -u \"$TARGET_USER\" env HOME=\"$TARGET_HOME\" bash -lc '$cmd'"
	else
		run "env HOME=\"$TARGET_HOME\" bash -lc '$cmd'"
	fi
}

backup_if_exists() {
	local dest=$1
	if [ -e "$dest" ] && [ ! -e "${dest}.bak" ]; then
		run "cp -a \"$dest\" \"${dest}.bak\""
	fi
}

install_file() {
	local src=$1
	local dest=$2
	local mode=$3
	local dest_dir
	dest_dir=$(dirname "$dest")
	backup_if_exists "$dest"
	run "install -d \"$dest_dir\""
	run "install -m \"$mode\" \"$src\" \"$dest\""
}

copy_tree_contents() {
	local src_dir=$1
	local dest_dir=$2
	run "install -d \"$dest_dir\""
	run "cp -a \"$src_dir\"/. \"$dest_dir\"/"
}

ensure_asus_repo() {
	local pacman_conf=/etc/pacman.conf
	grep -q '^\[g14\]$' "$pacman_conf" 2>/dev/null && return 0
	run "printf '\n[g14]\nServer = https://arch.asus-linux.org\n' >> \"$pacman_conf\""
}

apply_wal() {
	require_cmd wal
	require_cmd xwallpaper
	local wall
	run_as_target_user "mkdir -p \"$TARGET_HOME/.config/wallpaper\""
	run_as_target_user "cp -af \"$SCRIPT_DIR/wallpaper\"/. \"$TARGET_HOME/.config/wallpaper/\""
	wall=$(find "$SCRIPT_DIR/wallpaper" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) | sort | head -n 1)
	[ -n "$wall" ] || die "No wallpaper images found under $SCRIPT_DIR/wallpaper"
	run_as_target_user "xwallpaper --no-randr --zoom \"$wall\""
	run_as_target_user "wal -i \"$wall\""
}

install_packages_arch() {
	local -a pkgs=(
		xss-lock mtr qemu libvirt virt-manager qemu-full dnsmasq bridge-utils
		ttf-jetbrains-mono-nerd whois ufw firefox xwallpaper nsxiv
		xorg-server xorg-xrdb xorg-xinit picom neovim fd ripgrep git
		neofetch nvidia mpv htop python-pywal zsh
	)
	case "$PROFILE" in
		laptop|pc) pkgs+=(discord) ;;
	esac

	local -a missing=()
	local pkg
	for pkg in "${pkgs[@]}"; do
		pacman -Q "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
	done

	if [ "${#missing[@]}" -gt 0 ]; then
		run "pacman -S --noconfirm ${missing[*]}"
	else
		log "All Arch packages already installed."
	fi

	if [ "$PROFILE" = "laptop" ]; then
		ensure_asus_repo
		run "pacman -Syu --noconfirm"
		run "pacman -S --noconfirm asusctl supergfxctl rog-control-center power-profiles-daemon"
	fi
}

install_packages_void() {
	local -a pkgs=(
		firefox feh xorg-server xinit xsetroot picom vim git neofetch
		lightdm lightdm-gtk-greeter nvidia
	)
	local -a missing=()
	local pkg
	for pkg in "${pkgs[@]}"; do
		xbps-query -Rs "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
	done

	if [ "${#missing[@]}" -gt 0 ]; then
		run "xbps-install -Su ${missing[*]}"
	else
		log "All Void packages already installed."
	fi
}

install_packages() {
	require_root
	[ -n "$PROFILE" ] || die "--packages requires --profile"
	require_cmd grep
	if grep -q 'ID=arch' /etc/os-release; then
		install_packages_arch
	elif grep -q 'ID=void' /etc/os-release; then
		install_packages_void
	else
		die "Unsupported OS for package installation."
	fi
}

build_suckless() {
	apply_wal
	local dir
	for dir in dmenu st dwm slstatus slock; do
		run_as_target_user "cd \"$SCRIPT_DIR/src/$dir\" && make clean && make"
	done
}

install_suckless() {
	require_root
	apply_wal
	local dir
	for dir in dmenu st dwm slstatus slock; do
		run "cd \"$SCRIPT_DIR/src/$dir\" && make clean && make && make install"
	done
}

deploy_config() {
	local local_bin="$TARGET_HOME/.local/bin"
	run "install -d \"$TARGET_HOME/.config\" \"$local_bin\""

	install_file "$SCRIPT_DIR/.bashrc" "$TARGET_HOME/.bashrc" 0644
	install_file "$SCRIPT_DIR/.zshrc" "$TARGET_HOME/.zshrc" 0644
	install_file "$SCRIPT_DIR/.xinitrc" "$TARGET_HOME/.xinitrc" 0755
	install_file "$SCRIPT_DIR/newlook" "$local_bin/newlook" 0755
	install_file "$SCRIPT_DIR/WIPE.sh" "$local_bin/WIPE.sh" 0755

	copy_tree_contents "$SCRIPT_DIR/.config" "$TARGET_HOME/.config"
	copy_tree_contents "$SCRIPT_DIR/wallpaper" "$TARGET_HOME/.config/wallpaper"

	if [ "$(id -u)" -eq 0 ]; then
		run "chown -R \"$TARGET_USER:$TARGET_USER\" \"$TARGET_HOME/.config\" \"$TARGET_HOME/.local\" \"$TARGET_HOME/.bashrc\" \"$TARGET_HOME/.zshrc\" \"$TARGET_HOME/.xinitrc\""
	fi
}

deploy_session() {
	require_root
	install_file "$SCRIPT_DIR/picom.conf" "/etc/xdg/picom.conf" 0644
	install_file "$SCRIPT_DIR/xsessions/dwm.desktop" "/usr/share/xsessions/dwm.desktop" 0644
	install_file "$SCRIPT_DIR/xsessions/startdwm" "/usr/local/bin/startdwm" 0755
}

enable_services() {
	require_root
	[ -n "$PROFILE" ] || die "--enable-services requires --profile"

	run "systemctl enable libvirtd"

	if command -v usermod >/dev/null 2>&1; then
		run "usermod -aG libvirt \"$TARGET_USER\""
		run "usermod -aG kvm \"$TARGET_USER\""
	fi

	if command -v virsh >/dev/null 2>&1; then
		run "virsh -c qemu:///system net-autostart default || true"
		run "virsh -c qemu:///system net-start default || true"
	fi

	if [ "$PROFILE" = "laptop" ]; then
		run "systemctl enable --now power-profiles-daemon.service"
		run "systemctl enable --now supergfxd"
	fi
}

while [ $# -gt 0 ]; do
	case "$1" in
		--profile)
			shift
			[ $# -gt 0 ] || die "--profile requires a value"
			case "$1" in
				work|laptop|pc) PROFILE=$1 ;;
				*) die "Unsupported profile: $1" ;;
			esac
			;;
		--packages) DO_PACKAGES=1 ;;
		--build) DO_BUILD=1 ;;
		--install-suckless) DO_INSTALL_SUCKLESS=1 ;;
		--deploy-config) DO_DEPLOY_CONFIG=1 ;;
		--deploy-session) DO_DEPLOY_SESSION=1 ;;
		--enable-services) DO_ENABLE_SERVICES=1 ;;
		--target-user)
			shift
			[ $# -gt 0 ] || die "--target-user requires a value"
			set_target_user "$1"
			;;
		--all)
			DO_PACKAGES=1
			DO_BUILD=1
			DO_INSTALL_SUCKLESS=1
			DO_DEPLOY_CONFIG=1
			DO_DEPLOY_SESSION=1
			DO_ENABLE_SERVICES=1
			;;
		--dry-run) DRY_RUN=1 ;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "Unknown option: $1"
			;;
	esac
	shift
done

if [ -z "$TARGET_HOME" ]; then
	set_target_user "$TARGET_USER"
fi

[ "$DO_PACKAGES" -eq 1 ] || [ "$DO_BUILD" -eq 1 ] || [ "$DO_INSTALL_SUCKLESS" -eq 1 ] || \
[ "$DO_DEPLOY_CONFIG" -eq 1 ] || [ "$DO_DEPLOY_SESSION" -eq 1 ] || [ "$DO_ENABLE_SERVICES" -eq 1 ] || {
	usage
	exit 1
}

log "Target user: $TARGET_USER"
log "Target home: $TARGET_HOME"

[ "$DO_PACKAGES" -eq 0 ] || install_packages
[ "$DO_BUILD" -eq 0 ] || build_suckless
[ "$DO_INSTALL_SUCKLESS" -eq 0 ] || install_suckless
[ "$DO_DEPLOY_CONFIG" -eq 0 ] || deploy_config
[ "$DO_DEPLOY_SESSION" -eq 0 ] || deploy_session
[ "$DO_ENABLE_SERVICES" -eq 0 ] || enable_services

log "Done."
