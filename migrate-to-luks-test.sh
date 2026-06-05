#!/usr/bin/env bash
set -euo pipefail

# VM lab helper for migrating an unencrypted Pop!_OS root filesystem to LUKS.
# This is intentionally conservative. It does not delete the old root or resize
# partitions. If unallocated space exists on the old root disk, it can create
# the new LUKS target partition automatically.

OLDROOT="/mnt/oldroot"
NEWROOT="/mnt/newroot"
CRYPT_NAME="cryptroot"
CRYPT_DEV="/dev/mapper/${CRYPT_NAME}"
SELECTED_OLD_ROOT=""
SELECTED_TARGET_PART=""

status() {
  printf '[migrate] %s\n' "$*" >&2
}

warn() {
  printf '[migrate] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[migrate] ERROR: %s\n' "$*" >&2
  exit 1
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run this script as root from the live ISO environment."
}

check_dependencies() {
  local missing=()
  local cmd

  for cmd in cryptsetup rsync lsblk blkid findmnt mount umount chroot awk sed cp mkdir parted partprobe udevadm mkfs.ext4 df blockdev sfdisk; do
    have_cmd "$cmd" || missing+=("$cmd")
  done

  if ((${#missing[@]} > 0)); then
    printf 'Missing required commands:\n' >&2
    printf '  - %s\n' "${missing[@]}" >&2
    printf '\nInstall packages in the live environment if networking is available:\n' >&2
    printf '  sudo apt update && sudo apt install cryptsetup rsync util-linux parted e2fsprogs\n' >&2
    exit 1
  fi
}

is_block_device() {
  [[ -b "$1" ]]
}

is_mounted() {
  findmnt -rn --source "$1" >/dev/null 2>&1
}

mountpoint_for_device() {
  findmnt -rn --source "$1" -o TARGET
}

ensure_device_unmounted() {
  local dev="$1"
  local purpose="$2"
  local mountpoint=""
  local mount_output=""

  if ! mount_output="$(mountpoint_for_device "$dev" 2>/dev/null)"; then
    mount_output=""
  fi

  mountpoint="${mount_output%%$'\n'*}"
  if [[ -n "$mountpoint" ]]; then
    if [[ "$mountpoint" == "/" ]]; then
      die "$dev is mounted as /. You are booted into the installed system, not the live ISO. Shut down and boot with ./start_iso.sh, then choose the live/demo environment."
    fi

    warn "$dev is currently mounted at $mountpoint."
    warn "For $purpose, it needs to be unmounted first."
    read -r -p "Type YES to unmount ${dev} from ${mountpoint}: " confirm
    [[ "$confirm" == "YES" ]] || die "Cancelled because $dev is mounted."
    umount "$mountpoint"
  fi

  true
}

get_uuid() {
  blkid -s UUID -o value "$1"
}

get_fstype() {
  blkid -s TYPE -o value "$1" 2>/dev/null || true
}

read_partition() {
  local prompt="$1"
  local value

  while true; do
    read -r -p "$prompt" value
    if [[ "$value" == /dev/* ]] && is_block_device "$value"; then
      printf '%s\n' "$value"
      return 0
    fi
    printf 'Enter a real block partition path, for example /dev/vda3.\n' >&2
  done
}

partition_path() {
  local disk="$1"
  local number="$2"

  if [[ "$disk" =~ [0-9]$ ]]; then
    printf '%sp%s\n' "$disk" "$number"
  else
    printf '%s%s\n' "$disk" "$number"
  fi
}

parent_disk_for_partition() {
  local part="$1"
  local pkname

  pkname="$(lsblk -no PKNAME "$part" | head -n1)"
  [[ -n "$pkname" ]] || die "Could not determine parent disk for $part"
  printf '/dev/%s\n' "$pkname"
}

next_partition_number() {
  local disk="$1"

  lsblk -nrpo NAME "$disk" |
    awk -v disk="$disk" '
      $1 != disk {
        name=$1
        sub(/^.*[^0-9]/, "", name)
        if (name ~ /^[0-9]+$/ && name > max) max=name
      }
      END { print max + 1 }
    '
}

largest_free_region() {
  local disk="$1"
  local sector_size
  sector_size="$(blockdev --getss "$disk")"

  parted -m "$disk" unit s print free |
    awk -F: -v sector_size="$sector_size" '
      {
        last=$NF
        gsub(/;/, "", last)
      }
      tolower(last) ~ /free/ {
        if ($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+s$/) {
          start=$2
          end=$3
          size=$4
        } else {
          start=$1
          end=$2
          size=$3
        }
        gsub(/s/, "", start)
        gsub(/s/, "", end)
        gsub(/s/, "", size)
        if (size + 0 > best_size) {
          best_size=size + 0
          best_start=start + 0
          best_end=end + 0
        }
      }
      END {
        if (best_size > 0) {
          align=2048
          aligned_start=int((best_start + align - 1) / align) * align
          aligned_end=int((best_end + 1) / align) * align - 1
          if (aligned_end > best_end) {
            aligned_end -= align
          }
          aligned_size_sectors=aligned_end - aligned_start + 1
          aligned_size_mib=int((aligned_size_sectors * sector_size) / 1048576)
          if (aligned_size_sectors > 0 && aligned_size_mib > 0) {
            printf "%d %d %d\n", aligned_start, aligned_end, aligned_size_mib
          }
        }
      }
    '
}

trailing_free_region() {
  local disk="$1"
  local sector_size total_sectors disk_name sys_disk
  sector_size="$(blockdev --getss "$disk")"
  total_sectors="$(blockdev --getsz "$disk")"
  disk_name="$(basename "$disk")"
  sys_disk="/sys/block/${disk_name}"
  [[ -d "$sys_disk" ]] || die "Could not inspect kernel partition data at $sys_disk"

  local max_end=0 part_dir part_start part_size part_end
  for part_dir in "${sys_disk}/${disk_name}"*; do
    [[ -f "${part_dir}/start" && -f "${part_dir}/size" ]] || continue
    part_start="$(<"${part_dir}/start")"
    part_size="$(<"${part_dir}/size")"
    [[ "$part_start" =~ ^[0-9]+$ && "$part_size" =~ ^[0-9]+$ ]] || continue
    part_end=$((part_start + part_size - 1))
    if ((part_end > max_end)); then
      max_end="$part_end"
    fi
  done

  local align=2048
  local start end size_sectors size_mib
  start=$((((max_end + 1 + align - 1) / align) * align))
  end=$((total_sectors - 34))
  size_sectors=$((end - start + 1))
  size_mib=$(((size_sectors * sector_size) / 1048576))

  if ((size_sectors > 0 && size_mib > 0)); then
    printf '%d %d %d\n' "$start" "$end" "$size_mib"
  fi
}

largest_free_region_sfdisk() {
  local disk="$1"
  local sector_size
  sector_size="$(blockdev --getss "$disk")"

  sfdisk --list-free -o Start,Sectors "$disk" |
    awk -v sector_size="$sector_size" '
      $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
        start=$1 + 0
        sectors=$2 + 0
        align=2048
        aligned_start=int((start + align - 1) / align) * align
        skipped=aligned_start - start
        aligned_sectors=sectors - skipped
        aligned_sectors=int(aligned_sectors / align) * align
        if (aligned_sectors > best_sectors) {
          best_start=aligned_start
          best_sectors=aligned_sectors
        }
      }
      END {
        if (best_sectors > 0) {
          end=best_start + best_sectors - 1
          size_mib=int((best_sectors * sector_size) / 1048576)
          printf "%d %d %d\n", best_start, end, size_mib
        }
      }
    '
}

mounted_used_mib() {
  local mountpoint="$1"

  df -Pm "$mountpoint" | awk 'NR == 2 { print $3 }'
}

detect_old_root_candidates() {
  local tmp_base="/tmp/migrate-root-detect"
  local part

  mkdir -p "$tmp_base"
  while read -r part; do
    [[ -b "$part" ]] || continue
    [[ "$(get_fstype "$part")" == "ext4" ]] || continue
    is_mounted "$part" && continue

    local probe_dir="${tmp_base}/$(basename "$part")"
    mkdir -p "$probe_dir"
    if mount -o ro "$part" "$probe_dir" 2>/dev/null; then
      if [[ -f "${probe_dir}/etc/os-release" ]] &&
        grep -qiE 'pop!_os|pop_os|ubuntu|debian' "${probe_dir}/etc/os-release" &&
        [[ -d "${probe_dir}/etc" && -d "${probe_dir}/boot" ]]; then
        printf '%s\n' "$part"
      fi
      umount "$probe_dir" || true
    fi
    rmdir "$probe_dir" 2>/dev/null || true
  done < <(lsblk -rpno NAME,TYPE | awk '$2 == "part" { print $1 }')
}

select_old_root() {
  local -a candidates=()
  mapfile -t candidates < <(detect_old_root_candidates)

  if ((${#candidates[@]} == 1)); then
    status "Detected old root candidate: ${candidates[0]}"
    SELECTED_OLD_ROOT="${candidates[0]}"
    return 0
  fi

  if ((${#candidates[@]} > 1)); then
    printf 'Detected possible old root partitions:\n' >&2
    local i
    for i in "${!candidates[@]}"; do
      printf '  [%d] %s\n' "$((i + 1))" "${candidates[$i]}" >&2
    done
    printf 'Choose old root number, or press Enter to type a path manually: ' >&2
    local choice
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#candidates[@]})); then
      SELECTED_OLD_ROOT="${candidates[$((choice - 1))]}"
      return 0
    fi
  fi

  SELECTED_OLD_ROOT="$(read_partition "Old unencrypted root partition, for example /dev/vda3: ")"
}

create_target_partition_from_free_space() {
  local old_root="$1"
  local disk
  disk="$(parent_disk_for_partition "$old_root")"

  status "Looking for unallocated space on $disk"
  parted "$disk" unit MiB print free >&2
  status "Machine-readable free-space table:"
  parted -m "$disk" unit s print free >&2
  status "sfdisk free-space table:"
  sfdisk --list-free "$disk" >&2

  local free_info
  free_info="$(largest_free_region_sfdisk "$disk")"
  [[ -n "$free_info" ]] || die "No unallocated free space found on $disk. Leave free space during install or shrink the old root from the live ISO, then rerun this script."

  local free_start_sector free_end_sector free_size
  read -r free_start_sector free_end_sector free_size <<<"$free_info"

  local old_used required_size
  old_used="$(mounted_used_mib "$OLDROOT")"
  required_size=$((old_used + 4096))

  status "Old root currently uses about ${old_used} MiB."
  status "Largest usable aligned free region is about ${free_size} MiB."
  status "Sector range: ${free_start_sector}s to ${free_end_sector}s."
  status "Required free space estimate is ${required_size} MiB, including 4096 MiB working room."

  if ((free_size < required_size)); then
    die "Not enough unallocated space. Need at least ${required_size} MiB, found ${free_size} MiB."
  fi

  status "Unmounting old root before changing the partition table."
  umount "$OLDROOT"

  local part_num target_part
  part_num="$(next_partition_number "$disk")"
  target_part="$(partition_path "$disk" "$part_num")"

  printf '\n' >&2
  warn "This will create a new partition on $disk using unallocated space."
  warn "New partition: $target_part"
  warn "Start sector: ${free_start_sector}s"
  warn "End sector: ${free_end_sector}s"
  warn "No existing partition should be erased by this step, but partition table changes are still destructive if the wrong disk is selected."
  read -r -p "Type YES to create ${target_part}: " confirm
  [[ "$confirm" == "YES" ]] || die "Cancelled before partition creation."

  status "Creating partition ${target_part}"
  local new_size_sectors
  new_size_sectors=$((free_end_sector - free_start_sector + 1))
  printf '%s,%s,L\n' "$free_start_sector" "$new_size_sectors" | sfdisk --append "$disk"
  partprobe "$disk" || true
  udevadm settle

  local tries=0
  while [[ ! -b "$target_part" && $tries -lt 10 ]]; do
    sleep 1
    partprobe "$disk" || true
    udevadm settle
    tries=$((tries + 1))
  done

  [[ -b "$target_part" ]] || die "Created partition was not detected as $target_part"
  SELECTED_TARGET_PART="$target_part"
}

detect_efi_partition() {
  local candidate=""

  # Prefer a vfat partition with the standard EFI System Partition GUID.
  candidate="$(lsblk -rpno NAME,FSTYPE,PARTTYPE | awk 'tolower($2)=="vfat" && tolower($3)=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b" {print $1; exit}')"
  if [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  # Fall back to the first vfat partition. The user still gets a visible status line.
  candidate="$(lsblk -rpno NAME,FSTYPE | awk 'tolower($2)=="vfat" {print $1; exit}')"
  [[ -n "$candidate" ]] && printf '%s\n' "$candidate"
}

backup_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    cp -a "$path" "${path}.bak.$(date +%Y%m%d-%H%M%S)"
    status "Backed up $path"
  fi
}

update_fstab() {
  local new_root_uuid="$1"
  local efi_uuid="$2"
  local fstab="${NEWROOT}/etc/fstab"
  local tmp="${fstab}.tmp"

  mkdir -p "${NEWROOT}/etc"
  touch "$fstab"
  backup_file "$fstab"

  awk '
    BEGIN { replaced_root=0 }
    /^[[:space:]]*#/ || NF == 0 { print; next }
    $2 == "/" {
      print "# Replaced by migrate-to-luks-test.sh: " $0
      replaced_root=1
      next
    }
    { print }
    END {
      if (replaced_root == 0) {
        print "# Root entry added by migrate-to-luks-test.sh"
      }
    }
  ' "$fstab" >"$tmp"

  printf 'UUID=%s / ext4 defaults,noatime 0 1\n' "$new_root_uuid" >>"$tmp"

  if [[ -n "$efi_uuid" ]] && ! awk '$1 !~ /^#/ && $2 == "/boot/efi" { found=1 } END { exit found ? 0 : 1 }' "$tmp"; then
    printf 'UUID=%s /boot/efi vfat umask=0077 0 1\n' "$efi_uuid" >>"$tmp"
  fi

  mv "$tmp" "$fstab"
  status "Updated $fstab"
}

write_crypttab() {
  local luks_uuid="$1"
  local crypttab="${NEWROOT}/etc/crypttab"

  mkdir -p "${NEWROOT}/etc"
  backup_file "$crypttab"
  if [[ -f "$crypttab" ]] && grep -qE "^[[:space:]]*${CRYPT_NAME}[[:space:]]" "$crypttab"; then
    sed -i "s|^[[:space:]]*${CRYPT_NAME}[[:space:]].*|${CRYPT_NAME} UUID=${luks_uuid} none luks|" "$crypttab"
  else
    printf '%s UUID=%s none luks\n' "$CRYPT_NAME" "$luks_uuid" >>"$crypttab"
  fi
  status "Updated $crypttab"
}

bind_mount_chroot_fs() {
  local dir
  for dir in dev proc sys run; do
    mkdir -p "${NEWROOT}/${dir}"
    mount --bind "/${dir}" "${NEWROOT}/${dir}"
  done
}

run_chroot_updates() {
  status "Running update-initramfs inside chroot..."
  chroot "$NEWROOT" update-initramfs -u -k all

  if chroot "$NEWROOT" command -v bootctl >/dev/null 2>&1; then
    if findmnt -rn "${NEWROOT}/boot/efi" >/dev/null 2>&1; then
      status "systemd-boot tooling found. Trying bootctl update..."
      chroot "$NEWROOT" bootctl update || warn "bootctl update failed. Review bootloader setup manually."
    else
      warn "bootctl exists, but /boot/efi is not mounted. Skipping bootctl update."
    fi
  else
    warn "bootctl not found in chroot. Skipping systemd-boot update."
  fi

  if chroot "$NEWROOT" command -v kernelstub >/dev/null 2>&1; then
    warn "kernelstub exists, but this script will not guess kernel parameters."
    warn "Inside chroot, inspect: kernelstub -p"
    warn "You may need a root=UUID=<new-root-uuid> cryptdevice=UUID=<luks-uuid>:${CRYPT_NAME} style kernel option for your boot path."
  fi
}

print_recovery_help() {
  cat <<EOF

Changed:
  - Created LUKS container on the target partition.
  - Opened it as ${CRYPT_DEV}.
  - Created an ext4 filesystem inside the LUKS container.
  - Copied old root to ${NEWROOT}.
  - Updated ${NEWROOT}/etc/crypttab.
  - Updated ${NEWROOT}/etc/fstab.
  - Ran update-initramfs in the chroot.
  - Tried a conservative systemd-boot update if bootctl and /boot/efi were available.

Recovery/debug commands from the live ISO:
  lsblk -f
  cryptsetup luksOpen <target-partition> ${CRYPT_NAME}
  mount ${CRYPT_DEV} ${NEWROOT}
  mount <efi-partition> ${NEWROOT}/boot/efi
  mount --bind /dev ${NEWROOT}/dev
  mount --bind /proc ${NEWROOT}/proc
  mount --bind /sys ${NEWROOT}/sys
  mount --bind /run ${NEWROOT}/run
  chroot ${NEWROOT}
  cat /etc/crypttab
  cat /etc/fstab
  update-initramfs -u -k all
  bootctl status
  bootctl update

This VM lab script does not delete the old root partition. Keep it until the migrated system boots.
EOF
}

main() {
  require_root
  check_dependencies

  status "Current block devices:"
  lsblk -f
  printf '\n'

  local old_root target_part
  select_old_root
  old_root="$SELECTED_OLD_ROOT"
  [[ -n "$old_root" ]] || die "Could not select an old root partition."
  status "Using old root partition: $old_root"
  status "Old root filesystem type: $(get_fstype "$old_root")"

  [[ "$(get_fstype "$old_root")" != "crypto_LUKS" ]] || die "Old root already looks like a LUKS container."

  status "Checking whether old root is mounted..."
  ensure_device_unmounted "$old_root" "old-root read-only migration"
  status "Old root is not mounted."
  if [[ -e "$CRYPT_DEV" ]]; then
    die "$CRYPT_DEV already exists. Close it first with: cryptsetup close ${CRYPT_NAME}"
  fi
  status "No existing ${CRYPT_DEV} mapping found."

  status "Creating mount directories..."
  mkdir -p "$OLDROOT" "$NEWROOT"

  status "Mounting old root read-only at ${OLDROOT}"
  mount -o ro "$old_root" "$OLDROOT"
  status "Old root mounted successfully."

  create_target_partition_from_free_space "$old_root"
  target_part="$SELECTED_TARGET_PART"
  [[ -n "$target_part" ]] || die "Could not create or select a target partition."
  status "Using new LUKS target partition: $target_part"
  [[ "$old_root" != "$target_part" ]] || die "Old root and target partition must be different."

  ensure_device_unmounted "$target_part" "LUKS formatting"

  printf '\n'
  warn "The target partition will be erased: $target_part"
  warn "The old root partition will not be erased: $old_root"
  warn "This is for a VM lab first, not production."
  read -r -p "Type YES to create LUKS and erase ${target_part}: " confirm
  [[ "$confirm" == "YES" ]] || die "Cancelled before destructive actions."

  status "Creating LUKS container on $target_part"
  cryptsetup luksFormat "$target_part"

  status "Opening LUKS container as ${CRYPT_NAME}"
  cryptsetup open "$target_part" "$CRYPT_NAME"

  status "Creating ext4 filesystem in ${CRYPT_DEV}"
  mkfs.ext4 -L popos_cryptroot "$CRYPT_DEV"

  status "Mounting old root read-only at ${OLDROOT}"
  mount -o ro "$old_root" "$OLDROOT"

  status "Mounting new root at ${NEWROOT}"
  mount "$CRYPT_DEV" "$NEWROOT"

  status "Copying filesystem with rsync. This can take a while."
  rsync -aAXHv --numeric-ids "${OLDROOT}/" "${NEWROOT}/"

  local efi_part="" efi_uuid=""
  efi_part="$(detect_efi_partition || true)"
  if [[ -n "$efi_part" ]]; then
    efi_uuid="$(get_uuid "$efi_part" || true)"
    mkdir -p "${NEWROOT}/boot/efi"
    status "Detected EFI partition: $efi_part"
    if ! findmnt -rn "${NEWROOT}/boot/efi" >/dev/null 2>&1; then
      mount "$efi_part" "${NEWROOT}/boot/efi" || warn "Could not mount EFI partition at ${NEWROOT}/boot/efi"
    fi
  else
    warn "No vfat EFI partition detected. Bootloader update may need manual work."
  fi

  local luks_uuid new_root_uuid
  luks_uuid="$(get_uuid "$target_part")"
  new_root_uuid="$(get_uuid "$CRYPT_DEV")"
  [[ -n "$luks_uuid" ]] || die "Could not read LUKS UUID from $target_part"
  [[ -n "$new_root_uuid" ]] || die "Could not read filesystem UUID from $CRYPT_DEV"

  write_crypttab "$luks_uuid"
  update_fstab "$new_root_uuid" "$efi_uuid"

  status "Bind mounting /dev, /proc, /sys, and /run"
  bind_mount_chroot_fs

  run_chroot_updates
  print_recovery_help
}

main "$@"
