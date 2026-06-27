#!/bin/sh
# flash.sh — full raw write of a Banana Pi BPI-M4 (RTD1395) image to an SD card.
#
# The RTD1395 boot blob lives in the raw reserved area (sectors 0-1) BEFORE
# partition 1, so the image MUST be written as a full raw image from sector 0.
# A partition-only copy leaves those sectors zeroed -> "BOOT1 Rescue (0x15)"
# bootloop. This script does the unmount + raw dd, with an explicit erase guard.
#
# Usage:
#   ./flash.sh <image.img> <disk>
#
#   macOS:  ./flash.sh 2020-05-18-...-bpi-m4-...img /dev/disk4
#   Linux:  ./flash.sh 2020-05-18-...-bpi-m4-...img /dev/sdb
#
# WARNING: this ERASES the target disk completely.

set -eu

if [ "$#" -ne 2 ]; then
	echo "Usage: $0 <image.img> <disk>" >&2
	echo "  macOS example: $0 image.img /dev/disk4" >&2
	echo "  Linux example: $0 image.img /dev/sdb" >&2
	exit 2
fi

IMG="$1"
DISK="$2"

# --- Validate the image ----------------------------------------------------
if [ ! -f "$IMG" ]; then
	echo "Error: image file not found: $IMG" >&2
	exit 1
fi

# --- Validate the disk arg & build the per-OS device node ------------------
OS="$(uname -s)"
case "$OS" in
	Darwin)
		# Expect /dev/diskN; we write to the RAW node /dev/rdiskN (faster + clean raw write).
		case "$DISK" in
			/dev/disk[0-9]*) ;;
			/dev/rdisk[0-9]*)
				# Already a raw node; normalise to the buffered name for unmount.
				DISK="/dev/$(basename "$DISK" | sed 's/^r//')"
				;;
			*)
				echo "Error: on macOS DISK must look like /dev/diskN (got: $DISK)" >&2
				exit 1
				;;
		esac
		RAW="/dev/r$(basename "$DISK")"
		DD_BS="bs=4m"
		DD_EXTRA=""
		;;
	Linux)
		case "$DISK" in
			/dev/sd[a-z]|/dev/mmcblk[0-9]|/dev/nvme[0-9]n[0-9]) ;;
			*)
				echo "Error: on Linux DISK must be a whole-disk node like /dev/sdb or /dev/mmcblk0 (got: $DISK)" >&2
				exit 1
				;;
		esac
		RAW="$DISK"
		DD_BS="bs=4M"
		DD_EXTRA="conv=fsync"
		;;
	*)
		echo "Error: unsupported OS: $OS" >&2
		exit 1
		;;
esac

if [ ! -e "$DISK" ]; then
	echo "Error: disk node does not exist: $DISK" >&2
	exit 1
fi

# --- Confirm (explicit erase guard) ----------------------------------------
echo "About to write:"
echo "   image : $IMG"
echo "   disk  : $DISK   (raw node: $RAW)"
echo
echo "THIS WILL ERASE $DISK COMPLETELY."
printf 'Type ERASE to continue: '
read -r CONFIRM
if [ "$CONFIRM" != "ERASE" ]; then
	echo "Aborted." >&2
	exit 1
fi

# --- Unmount + raw dd ------------------------------------------------------
case "$OS" in
	Darwin)
		echo "Unmounting $DISK ..."
		diskutil unmountDisk "$DISK"
		echo "Writing (raw) to $RAW ..."
		# shellcheck disable=SC2086
		sudo dd if="$IMG" of="$RAW" $DD_BS
		sync
		echo "Done. Ejecting $DISK ..."
		diskutil eject "$DISK" || true
		;;
	Linux)
		echo "Writing to $RAW ..."
		# shellcheck disable=SC2086
		sudo dd if="$IMG" of="$RAW" $DD_BS $DD_EXTRA
		sync
		echo "Done."
		;;
esac

echo "Flash complete. Set SW2=0 for SD boot, then power the board."
