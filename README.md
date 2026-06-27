# Banana Pi BPI-M4 (Realtek RTD1395) — OS Flash & Recovery Runbook

This is a recovery runbook for the **original** Banana Pi **BPI-M4**, built on the
**Realtek RTD1395** SoC (ARM64). The M4 ships a **4.9 BSP kernel** and never moved off it
— Armbian treats it as *wontfix*, so the vendor BSP image is what you have.

- **Last official Linux image:**
  `2020-05-18-ubuntu-18.04-mate-...-bpi-m4-aarch64-sd-emmc.img`
- **Default login:** `pi` / `bananapi` (also `root` / `bananapi`) — vendor-documented defaults.
- **Stock hostname:** `bpi-iot-ros-ai`
- **SSH:** `sshd` is enabled by default on the stock image.

Every gotcha below comes from a real recovery. Read sections 3 and 6 before you start —
they are the two that waste the most time.

---

## 1. Hardware you need

- A **USB-TTL UART adapter** (FTDI / CP2102 / CH340) for the 3-pin debug header — **115200 8N1**.
  This is non-optional for diagnosing boot failures; the on-board ROM prints its whole boot
  story over this serial line.
- A way to **read/write the SD card on a host** (USB card reader).
- **5V power** for the board.

---

## 2. Flash the image (the RIGHT way)

The image **MUST** be written as a **full raw image from sector 0** — not file-by-file,
not "burn into a partition".

**macOS:**

```sh
# Find the disk (e.g. /dev/disk4)
diskutil list

# Unmount the whole disk (NOT eject)
diskutil unmountDisk /dev/diskN

# Write to the RAW node (rdiskN) — much faster, and required for a clean raw write
sudo dd if=<img> of=/dev/rdiskN bs=4m
```

**Linux:**

```sh
sudo dd if=<img> of=/dev/sdX bs=4M conv=fsync
```

> A convenience wrapper that does the unmount + raw `dd` with a guard lives in
> [`scripts/flash.sh`](scripts/flash.sh).

### Why file-by-file / Etcher-into-a-partition does NOT work

The Realtek **boot blob lives in the raw reserved area before partition 1** — sectors 0–1
hold the `SDMMC_BOOT` magic plus the `BRLYT` / `BBBB` descriptor. A partition-only copy
(drag files into the FAT partition, or restore just the filesystems) leaves those sectors
**zeroed**, and the board dies with:

```
hwsetting fail: BOOT1 Rescue (0x15)
```

in a bootloop. Only a full raw `dd` from sector 0 lays the boot blob down correctly.

---

## 3. The boot-select switch SW2 (critical, easy to miss)

`SW2` is a **tiny slide switch on the BOTTOM of the board**, next to the microSD slot.
It is **NOT** the push button — don't confuse them.

| SW2 | Behavior |
|-----|----------|
| `SW2 = 0` | Boot from **SD** if a bootable card is present, otherwise fall back to eMMC. **Use this for SD boot.** |
| `SW2 = 1` | **eMMC-only.** SD card is ignored entirely. |

If you flashed the SD correctly and it *still* won't boot from it — **check SW2 first.** A
board left in `SW2=1` will silently ignore a perfectly good card.

---

## 4. Verify boot over UART (115200 8N1)

A **healthy** boot ROM prints stage markers in this order:

```
C1
C2
C3
hwsetting size: ...
Welcome to FSBL
...
U-Boot 2015.07
```

**Failure signature — missing/zeroed boot blob:**

```
hwsetting fail: BOOT1 Rescue (0x15)
```

followed by a `[GO]` / `ST` retry loop. This means the raw boot area is missing →
**reflash the full raw image (section 2).**

> ⚠️ **Garbage on the UART at every baud rate? Check the GND wire FIRST.**
> A loose ground looks *exactly* like a baud mismatch and will waste hours of
> baud-hunting. Verify, in order: **common ground (GND)**, then **TX↔RX** not swapped,
> then baud. Ground first, always.

---

## 5. Device numbering gotcha (counter-intuitive)

On this board's 4.9 kernel the numbering is the **opposite** of what you'd expect:

| Device | Node | Layout |
|--------|------|--------|
| **SD card** | `/dev/mmcblk0` | `p1` = BPI-BOOT (FAT), `p2` = BPI-ROOT (ext4) |
| **eMMC** | `/dev/mmcblk1` | often **no** partition table |

So the correct root for an SD boot is **`root=/dev/mmcblk0p2`**. The stock `uEnv.txt` and
the U-Boot compiled-in default already use `mmcblk0p2` — that part is correct out of the box.

---

## 6. "Drops to initramfs rescue shell / root=/dev/mmcblk1p2" — the saved-env trap

**Symptom:** boot reaches the kernel, but:

```
ALERT! /dev/mmcblk1p2 does not exist. Dropping to a shell!
(initramfs)
```

and `cat /proc/cmdline` shows `root=/dev/mmcblk1p2` — a device that doesn't exist on an
SD boot.

**Cause:** a **corrupted SAVED U-Boot environment in flash**. At some point someone ran
`setenv root .../mmcblk1p2; saveenv` (an abandoned eMMC-boot attempt). That saved env
**overrides the correct `uEnv.txt`**. This is **NOT** fixable by editing any file on the
card — `uEnv.txt` is *already* correct; the stale saved env wins.

### Permanent fix — in the U-Boot console

Interrupt autoboot over UART (press **Esc** or **Tab** while it counts down), then:

```
env default -a
saveenv
reset
```

This restores the **factory environment** (which correctly imports `uEnv.txt` →
`mmcblk0p2`), and the board boots unattended from then on. See
[`scripts/fix-saved-env.txt`](scripts/fix-saved-env.txt) for a copy-paste snippet.

### Emergency limp-in (boot once without fixing the env)

At the `(initramfs)` prompt, create the missing node as an alias of the SD's `p2` (same
major:minor `179:34`) and exit so init resumes:

```sh
mknod /dev/mmcblk1p2 b 179 34
exit
```

This gets you one boot; it does **not** survive a power cycle. Do the `env default -a`
fix for a permanent solution.

---

## 7. Manual boot from the U-Boot console (if autoboot fails)

- The SD is the **`sd`** interface in U-Boot, **not `mmc`**. `mmc dev` only sees the eMMC.
  Set:

  ```
  setenv device sd
  ```

- **`bootm` / `booti` will FAIL.** The `uImage` here is a Realtek firmware blob, so a
  generic image-boot reports `Wrong Image Format` → CPU abort. Use the **vendor recipe**:

  ```
  run uenvcmd
  ```

  which expands to
  `run ahello abootargs aload_dtb aload_kernel aload_rootfs aload_audio aboot`,
  where `aboot=go all`.

- **SD RX-tuning is unstable on SDR104.** Each `sd rescan` flips between good
  (`29818 MB`) and fail (`1024 sectors / 0 MB`). **Loop `sd rescan`** until the capacity
  reads sane, then load + boot inside that good window:

  ```
  sd rescan
  sd rescan
  ...   # repeat until capacity prints ~29818 MB
  run uenvcmd
  ```

---

## 8. SD flakiness — handle with care

This board/card combo flaps. `dmesg` shows things like:

```
mmc0: card b368 removed
```

then a re-detect. Under sustained read load, a `dd` of the whole card can **SIGBUS** and
remount the rootfs **read-only**, which kills `sshd`.

- **Do NOT bulk-`dd` / full-scan the SD while the rootfs is live on it.**
- If you need to image the card, **pull it and image on another host.**
- Prefer a **high-quality SD card**.
- For production, consider **migrating the rootfs to the (stable) eMMC**.

---

## 9. Confirm success

```sh
ssh pi@<board-ip>          # password: bananapi
```

```sh
cat /proc/device-tree/model     # → Sinovoip_Bananapi_M4
findmnt /                        # → root on /dev/mmcblk0p2
uname -r                         # → 4.9.119-BPI-M4-Kernel
```

If all three match, you're recovered.

---

## Appendix: reference data (from a real recovered board)

### `uEnv.txt` — load-bearing lines

```
root=/dev/mmcblk0p2 rw rootfstype=ext4 rootwait
console=earlycon=uart8250,mmio32,0x98007800 console=tty1 fbcon=map:0 console=ttyS0,115200
bootopts=loglevel=8 initcall_debug=0
abootargs=setenv bootargs board=${board} console=${console} root=${root} fsck.mode=force fsck.repair=yes service=${service} sdmmc_on=${sdmmc_on} ${bootopts}
uenvcmd=run ahello abootargs aload_dtb aload_kernel aload_rootfs aload_audio aboot
```

### `lsblk -f` — disk layout

```
NAME          FSTYPE LABEL    MOUNTPOINT
mmcblk0                                        (SD card)
├─mmcblk0p1   vfat   BPI-BOOT /media/pi/BPI-BOOT
└─mmcblk0p2   ext4   BPI-ROOT /
mmcblk1                                        (eMMC — no filesystem)
mmcblk1boot0
mmcblk1boot1
mmcblk1rpmb
```

### `fdisk /dev/mmcblk0` — partition table (DOS, disk id `0xc69bd2d7`)

```
Device         Boot  Start      End  Sectors  Size Id Type
/dev/mmcblk0p1       204800   729087   524288  256M  c W95 FAT32 (LBA)
/dev/mmcblk0p2       729088 14940159 14211072  6.8G 83 Linux
```

Disk is **29.1 GiB**; only the first ~7.1 GiB is partitioned (room to grow the rootfs).

### U-Boot boot flow

```
bootcmd       = run boot_normal
boot_normal   = <import uEnv.txt> ; run uenvcmd
loadbootenv   = fatload sd 0:1 0x1500000 bananapi/bpi-m4/linux/uEnv.txt
checksd       = fatinfo sd 0:1
uenvcmd       = run ahello abootargs aload_dtb aload_kernel aload_rootfs aload_audio aboot
aboot         = go all
```

### Boot files directory: `bananapi/bpi-m4/linux/`

```
u-boot-bpi-m4.bin
uEnv.txt
uImage
uInitrd
rtd-1395-bananapi-m4-1GB.dtb
rtd-1395-bananapi-m4-2GB.dtb
bluecore.audio
```

---

## License

[MIT](LICENSE).
