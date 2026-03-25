#!/bin/sh
set -eu

usage() {
	cat <<'EOF'
Usage: WIPE.sh /dev/sdX [blkdiscard|zero|random|shred]

This script is intended to be run from a live environment against an
unmounted target disk. It refuses to run on partitions and asks for multiple
confirmations before doing anything destructive.

Methods:
  blkdiscard  Best fit for SSD/NVMe when supported. Fast and preferred.
  zero        Single zero-fill pass. Good generic baseline for HDDs.
  random      Single random-fill pass. Slower, usually unnecessary on SSDs.
  shred       3-pass overwrite. HDD-oriented, very slow on large disks.

Examples:
  sudo ./WIPE.sh /dev/nvme0n1 blkdiscard
  sudo ./WIPE.sh /dev/sda zero
EOF
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		printf 'Missing required command: %s\n' "$1" >&2
		exit 1
	}
}

confirm() {
	prompt=$1
	printf '%s [y/N]: ' "$prompt"
	read -r answer
	case "$answer" in
		y|Y|yes|YES) return 0 ;;
		*) return 1 ;;
	esac
}

[ $# -ge 1 ] || {
	usage
	exit 1
}

TARGET=$1
METHOD=${2:-blkdiscard}

case "$METHOD" in
	blkdiscard|zero|random|shred) ;;
	*)
		printf 'Unsupported wipe method: %s\n\n' "$METHOD" >&2
		usage
		exit 1
		;;
esac

if [ "$(id -u)" -ne 0 ]; then
	printf 'Run this script as root from a live environment.\n' >&2
	exit 1
fi

require_cmd lsblk
require_cmd wipefs
require_cmd blockdev

[ -b "$TARGET" ] || {
	printf 'Target is not a block device: %s\n' "$TARGET" >&2
	exit 1
}

TYPE=$(lsblk -dn -o TYPE "$TARGET" 2>/dev/null || true)
[ "$TYPE" = "disk" ] || {
	printf 'Refusing to wipe non-disk target: %s (type=%s)\n' "$TARGET" "${TYPE:-unknown}" >&2
	exit 1
}

printf '\nTarget disk summary:\n'
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,MODEL "$TARGET"
printf '\nMounted descendants:\n'
lsblk -nrpo NAME,MOUNTPOINTS "$TARGET"

if lsblk -nrpo MOUNTPOINTS "$TARGET" | grep -q '[^[:space:]]'; then
	printf '\nSome target partitions are still mounted. Unmount them first.\n' >&2
	exit 1
fi

printf '\nSelected wipe method: %s\n' "$METHOD"
printf 'This will permanently destroy all data on %s.\n' "$TARGET"

confirm "Continue with destructive wipe?" || exit 1
printf 'Type the full disk path to confirm: '
read -r typed
[ "$typed" = "$TARGET" ] || {
	printf 'Confirmation did not match. Aborting.\n' >&2
	exit 1
}

case "$METHOD" in
	blkdiscard)
		require_cmd blkdiscard
		blkdiscard -f "$TARGET"
		;;
	zero)
		require_cmd dd
		dd if=/dev/zero of="$TARGET" bs=16M status=progress conv=fsync
		;;
	random)
		require_cmd dd
		dd if=/dev/urandom of="$TARGET" bs=16M status=progress conv=fsync
		;;
	shred)
		require_cmd shred
		shred -v -n 3 -z "$TARGET"
		;;
esac

wipefs -a "$TARGET"
blockdev --flushbufs "$TARGET"

printf '\nWipe complete for %s using %s.\n' "$TARGET" "$METHOD"
printf 'For SSD/NVMe, blkdiscard is generally the preferred option when supported.\n'
