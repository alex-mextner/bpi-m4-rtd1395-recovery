# Banana Pi BPI-M4 (Realtek RTD1395) — Boot, Flash & Recovery Runbook

Recovery runbook for the **original** Banana Pi **BPI-M4** (Realtek **RTD1395** SoC, ARM64).
The M4 ships a **4.9 BSP kernel** and never moved off it — Armbian treats it as *wontfix*, so
the vendor BSP image is all you get.

- **Last official Linux image:** `2020-05-18-ubuntu-18.04-mate-...-bpi-m4-aarch64-sd-emmc.img`
- **Default login:** `pi` / `bananapi` (also `root` / `bananapi`)
- **Stock hostname:** `bpi-iot-ros-ai`
- **SSH:** `sshd` is enabled by default on the stock image.

Every gotcha below comes from a real multi-day recovery.

> **Read §3 (UART), §5 (SW2) and §6 (the SDR104 card-model trap) before you touch anything.**
> §6 is the one that wasted days: a perfectly good image on a "good" card boots ~1 time in 12
> because of a stage-2 U-Boot bug, and almost every other failure you'll see is downstream of it.

## TL;DR — if the board won't boot

1. Wire up **UART at 115200 8N1** and watch the boot (§3). The ROM tells you exactly where it dies.
2. `hwsetting fail: BOOT1 Rescue (0x15)` loop → the boot blob is gone → **full raw `dd` reflash** (§4).
3. Board ignores a freshly-flashed SD → **check SW2** (§5). `SW2=1` silently ignores the card.
4. Boot reaches U-Boot then loops `do_booti failed` / `Bad gzipped data` → `BPI-M4>` → **stage-2
   U-Boot can't read your SD card model at SDR104** (§6). **Swap to a different-brand SD card** —
   that is the real fix. Or migrate to eMMC (§7).
5. Drops to `(initramfs)` with `root=/dev/mmcblk1p2 does not exist` → **don't chase the saved-env
   ghost** (§8): run `printenv root` at the U-Boot console first. On this board it was an
   initramfs alias, not a bad env.

---

## 1. The boot chain (so the failure signatures make sense)

Boot is a **closed Realtek mask ROM chainloading two separate U-Boots**:

```
SPI-NOR mask ROM ("Magellan")  → reads hwsetting → FSBL
  → stage-1 U-Boot (2015.07, Feb 2020, lives in eMMC/SPI)
      → loads u-boot-bpi-m4.bin from the boot device
        → stage-2 U-Boot (2015.07, May 2020, from the boot device)
            → imports uEnv.txt → run uenvcmd (aboot=go all) → kernel
```

Two consequences that bite:

- **Boot-device *selection* lives in the closed firmware** (hwsetting + SW2). You cannot force it
  from the U-Boot environment, a file, or the dtb. §5 and §7 are about working *with* it.
- **Stage-1 and stage-2 are different binaries with different SD behavior.** Stage-1 reads the SD
  fine; stage-2 is the one that fails SDR104 tuning (§6). "I replaced the card and it still fails"
  usually means you hit the same stage-2 bug, not a second bad card.

---

## 2. Hardware you need

- A **USB-TTL UART adapter** (FTDI / CP2102 / CH340) for the 3-pin debug header — **115200 8N1**.
  Non-optional for diagnosing boot failures; the ROM prints its whole boot story over this line.
- A way to **read/write the SD card on a host** (USB card reader).
- **At least two SD cards of different brands** — see §6, the card model is the single biggest
  variable on this board.
- **5V power** for the board.

---

## 3. UART debug console — 115200 8N1 (do this first)

**Settings: 115200 baud, 8 data bits, no parity, 1 stop bit (8N1).** Nothing else. There is no
"try other baud rates" step on this board — it is always 115200.

Wire TX↔RX (crossed), RX↔TX, and **GND↔GND**. Then log the console:

```sh
# repo helper — tees the serial port to stdout AND a file you can grep later
python3 scripts/uart-logger.py /dev/cu.usbserial-XXXX 115200 boot.log
```

(`scripts/uart-logger.py` autodetects a `usbserial`/`ttyUSB` adapter if you omit the device, and
defaults to 115200.)

A **healthy** boot ROM prints stage markers roughly in this order:

```
C1
C2
C3
hwsetting size: ...
Welcome to FSBL
...
U-Boot 2015.07 (... Feb ... 2020 ...)   <- stage-1
...
U-Boot 2015.07 (... May 18 2020 ...)    <- stage-2
...
Starting kernel ...
```

> ### ⚠️ Garbage at *every* baud rate? Check GND FIRST.
> A loose ground looks **exactly** like a baud mismatch and will burn hours of baud-hunting.
> Verify in this order, every time: **(1) common ground (GND)**, **(2) TX↔RX not swapped**,
> **(3) baud (always 115200 here)**. Ground first. This cost real hours on this board.

### Failure signatures you'll read on the UART

| What you see | Meaning | Section |
|---|---|---|
| `hwsetting fail: BOOT1 Rescue (0x15)` looping | raw boot blob (sectors 0–1) zeroed | §4 |
| `Tuning RX fail` / `phase_map=0x00000000` / `capacity 1024 sectors / 0 MB` | stage-2 SDR104 tuning failed to read the SD | §6 |
| `Wrong Image Format` / `Bad gzipped data` / `Decompress FAIL` / `ERROR do_booti failed!` → `BPI-M4>` | downstream of the SDR104 read failure — kernel couldn't be loaded | §6 |
| `Fail to get hwsetting 0x15` | flaky SW2 / boot-select; reseat SW2, verify per §5 | §5 |
| kernel boots then `root=/dev/mmcblk1p2 does not exist` → `(initramfs)` | device renumber / cmdline alias — NOT necessarily a bad env | §8 |

---

## 4. Flash the image (the RIGHT way)

The image **MUST** be written as a **full raw image from sector 0** — not file-by-file, not
"burn into a partition".

**macOS:**

```sh
diskutil list                          # find the disk, e.g. /dev/disk4
diskutil unmountDisk /dev/diskN        # unmount the whole disk (NOT eject)
sudo dd if=<img> of=/dev/rdiskN bs=4m  # write to the RAW node (rdiskN) — required & faster
```

**Linux:**

```sh
sudo dd if=<img> of=/dev/sdX bs=4M conv=fsync
```

> A wrapper that does the unmount + raw `dd` with an `ERASE` guard lives in
> [`scripts/flash.sh`](scripts/flash.sh).

### Why file-by-file / Etcher-into-a-partition does NOT work

The Realtek **boot blob lives in the raw reserved area before partition 1** — sectors 0–1 hold
the `SDMMC_BOOT` magic plus the `BRLYT` / `BBBB` descriptor. A partition-only copy leaves those
sectors **zeroed**, and the board dies with `hwsetting fail: BOOT1 Rescue (0x15)` in a bootloop.
Only a full raw `dd` from sector 0 lays the boot blob down correctly.

---

## 5. The boot-select switch SW2

`SW2` is a **tiny slide switch on the BOTTOM of the board**, next to the microSD slot. It is
**NOT** the push button — don't confuse them.

| SW2 | Behavior |
|-----|----------|
| `SW2 = 0` | Boot from **SD** if a bootable card is present, otherwise fall back to **eMMC**. Normal Linux use. |
| `SW2 = 1` | **USB-download mode** for the Realtek flash tool (per the BPI wiki). On this specific unit `SW2=1` also produced eMMC reads / `Fail to get hwsetting 0x15` — it is flaky; **verify on your unit, don't assume.** |

Key facts:

- If you flashed the SD correctly and it *still* won't boot — **check SW2 first.** A board left in
  `SW2=1` silently ignores a perfectly good card.
- **To boot from eMMC: `SW2=0` AND remove the SD physically** (see §7). `SW2=1` is not a reliable
  "boot eMMC" switch on this unit.
- **You cannot force eMMC boot while a *bootable* SD is inserted.** The RTD1395 ROM hard-prefers a
  bootable SD. This is why "boot eMMC, keep the SD in as storage" needs the SD to be a *non-bootable*
  plain data card (§7).

---

## 6. ★ The real root cause: stage-2 U-Boot SDR104 tuning fails on certain SD card models

This is the section that matters. **The image is fine. The flash is fine. The card is the variable.**

### Symptom

The board powers on, reaches U-Boot, and then loops:

```
... Tuning RX fail ...           (sometimes)
Wrong Image Format for do_booti command
Not raw Image, Starting Decompress Image.gz...
Error: Bad gzipped data
Decompress FAIL!!
ERROR do_booti failed!
...
Enter console mode, disable watchdog ...
BPI-M4>
```

Occasionally (~1 boot in 12) it just works and reaches Linux. **That intermittency is the tell.**

### Mechanism

Stage-1 U-Boot reads the SD fine (`RX phase_map=0xffff81ff`, full `29818 MB`). Stage-2 U-Boot
(loaded *from* the SD) tries to switch the card to **SDR104** and run RX tuning — and on some card
models that tuning fails (`phase_map=0x00000000`, `Tuning RX fail`, capacity collapses to
`1024 sectors / 0 MB`). With the card unreadable, stage-2 can't load the kernel → `do_booti failed`
→ `BPI-M4>`. It's a per-boot lottery: when tuning happens to land in a good window, the board boots.

At the BSP source level: the SD-target stage-2 U-Boot is built from `rtd1395_sd_bananapi_defconfig`
with **`CONFIG_SD30` enabled**, which is the only thing that turns on the 1.8 V switch → SDR104 →
RX/TX-tuning path. There is **no runtime knob** to disable it — not the env, not `uEnv.txt` (read
*after* the SD is already up), not the dtb (the U-Boot SD driver has hardcoded register bases and
does no DT parsing; the dtb only affects the *kernel's* separate SD driver).

### ★ Fix (confirmed on hardware): use a different-brand SD card

Two cards of the **same model** (SCR `2c58043`) both failed stage-2 tuning identically. A
**different-brand** card (SCR `2358043`) boots cleanly — stage-2 never enters SDR104 at all
(`SD: init done, no error`, full `30250 MB`), loads the kernel, and Linux 4.9.119 comes up. So the
incompatibility is specific to *that card model × RTD1395 SDR104*. **Swapping to a different-brand
card is the simplest real fix** — and "I swapped cards and it still fails" almost always means you
swapped to the *same model*. Try a genuinely different brand/controller.

### Fallback fixes (if you're stuck with one card model)

1. **Migrate the rootfs to eMMC and boot from eMMC** (§7). The eMMC has no SDR104 path, so it
   sidesteps the bug entirely. This is the most robust outcome.
2. **Rebuild stage-2 U-Boot with `CONFIG_SD30` disabled** (`//#define CONFIG_SD30` in
   `u-boot-rtk/include/configs/rtd1395_qa_sd_bananapi.h`) → stage-2 reads the SD at plain 50 MHz HS
   with no tuning. Copy the built `u-boot.bin` over
   `BPI-BOOT/bananapi/bpi-m4/linux/u-boot-bpi-m4.bin`. Needs the BSP aarch64 toolchain; logically
   sound (HS/3.3 V needs no tuning) but unproven on this hardware. No vendor binary ships with SD30 off.
3. **Brute-reboot** until tuning hits a good window. Works, miserable, not a fix.

---

## 7. Migrate to eMMC, the device-renumber trap, and `root=UUID`

The eMMC is stable (no SDR104 lottery), so the durable endgame is to run the system from eMMC.

### Installing to eMMC

From a **booted Linux** (you got one good SD boot, or you're on a compatible card): clone the SD
rootfs to the eMMC (`rsync` the filesystem, or the vendor `bpi-copy` / image installer). Do **not**
raw-`dd` a whole SD image onto `/dev/mmcblk1` blindly — the eMMC needs its boot0 preloader laid
down too; an image installer handles that, a partition-only rsync needs the boot area already present.

### ⚠️ The device-numbering trap — use `root=UUID=`

Node numbering **renumbers based on whether the SD is present**:

| State | SD card | eMMC |
|---|---|---|
| SD inserted | `/dev/mmcblk0` | `/dev/mmcblk1` |
| SD removed | — | `/dev/mmcblk0` |

So an eMMC clone hard-coded with `root=/dev/mmcblk1p2` works *with the SD in*, then fails
`ALERT! /dev/mmcblk1p2 does not exist → (initramfs)` the moment you pull the SD (eMMC became
`mmcblk0`). **Fix: set `root=UUID=<rootfs-uuid>`** in both `uEnv.txt` and `/etc/fstab` — a UUID
resolves to the right partition regardless of node numbering. (On the recovered board the eMMC
rootfs UUID is `c54ba81b-3b9d-4cb7-8cb0-6d907765fbb8`.)

### Booting eMMC standalone

`SW2 = 0` **and the SD physically removed at power-on.** Confirmed working: the ROM falls back to
eMMC, the `root=UUID` kernel finds its rootfs as `mmcblk0p2`, Linux boots unattended.

### "Boot eMMC but keep the SD in as storage" — the hard limitation

This is **not** achievable while the SD is a *bootable* card:

- `SW2=1` does not force eMMC (it still prefers the SD / goes flaky).
- Zeroing the SD's `BRLYT` descriptor (sector 1) does nothing — hwsetting still reads, SD still boots.
- Killing just the SD's BPI-BOOT FAT makes stage-1 fall through to the eMMC u-boot, **but** that
  eMMC u-boot has a bad-CRC/default env that still hunts the kernel on the now-dead SD FAT →
  `do_booti failed` → `BPI-M4>` hang. So you lose the SD boot without gaining the eMMC boot.

The only path that should work: make the SD a **fully non-bootable plain data card** — strip *every*
boot signature (the raw boot blob, not just the FAT), give it a fresh partition table + a single
data partition — so the ROM never tries to boot it and falls cleanly to eMMC. (Documented as the
known-good approach; not verified end-to-end in this session.)

Working setups that *do* hold today:

- **eMMC boot + SD as storage:** `SW2=0`, SD **out** at power-on, then **hotplug** the SD after
  Linux is up and mount it for storage.
- **SD as main system, eMMC as backup:** keep the (larger, 29 G) SD as root; clone to eMMC as a
  cold spare.

---

## 8. "Drops to `(initramfs)` / `root=/dev/mmcblk1p2`" — verify before chasing the saved-env ghost

**Symptom:** the kernel starts, then `ALERT! /dev/mmcblk1p2 does not exist → (initramfs)`, and
`cat /proc/cmdline` shows `root=/dev/mmcblk1p2`.

**Do not assume a corrupted U-Boot saved env.** On this board that was a **red herring**: at the
`BPI-M4>` console, `printenv root` showed `/dev/mmcblk0p2` (already correct), and the `mmcblk1p2`
in the kernel cmdline was an **initramfs device-alias artifact**, not a stored env value. Running
`env default -a; saveenv` was chasing nothing.

**So: check `printenv root` at the U-Boot console first.**

- If `printenv root` is already correct → it's the device-renumber/alias issue (§7); fix with
  `root=UUID=` and verify the card-presence state you're actually booting in.
- If `printenv root` really *is* `mmcblk1p2` → then you have a genuinely corrupted saved env (a real
  failure mode on other units); reset it:

  ```
  env default -a
  saveenv
  reset
  ```

  See [`scripts/fix-saved-env.txt`](scripts/fix-saved-env.txt).

**Emergency limp-in (one boot, no fix):** at `(initramfs)`, alias the SD's `p2` (major:minor
`179:34`) and exit so init resumes — does NOT survive a power cycle:

```sh
mknod /dev/mmcblk1p2 b 179 34
exit
```

---

## 9. Manual boot from the U-Boot console

- The SD is the **`sd`** interface in U-Boot, **not `mmc`** (`mmc dev` only sees the eMMC).
  `setenv device sd`.
- **`bootm` / `booti` FAIL** — the `uImage` is a Realtek firmware blob, so a generic image-boot
  reports `Wrong Image Format` → CPU abort. Use the vendor recipe: `run uenvcmd` (expands to
  `run ahello abootargs aload_dtb aload_kernel aload_rootfs aload_audio aboot`, `aboot=go all`).
- **If stage-2 SD tuning is flaky (§6):** loop `sd rescan` until capacity prints sane
  (~`29818 MB`), then `run uenvcmd` inside that good window.

---

## 10. SD flakiness — handle with care

On a card that flaps (§6), `dmesg` shows `mmc0: card ... removed` then a re-detect. Under sustained
read load a whole-card `dd` can **SIGBUS**, remount the rootfs **read-only**, and kill `sshd` —
knocking the board off the network (needs a power-cycle).

- **Do NOT bulk-`dd` / full-scan the SD while the rootfs is live on it.** Light I/O only.
- To image the card, **pull it and image on another host.**
- The durable fix is a compatible card (§6) or eMMC (§7).

---

## 11. Confirm success

```sh
ssh pi@<board-ip>                 # password: bananapi
cat /proc/device-tree/model       # → Sinovoip_Bananapi_M4
findmnt /                         # → root on mmcblk0p2 (or your eMMC UUID)
uname -r                          # → 4.9.119-BPI-M4-Kernel
```

---

## Appendix: reference data (from a real recovered board — historical, layout-stable)

### `uEnv.txt` — load-bearing lines (SD)

```
root=/dev/mmcblk0p2 rw rootfstype=ext4 rootwait
console=earlycon=uart8250,mmio32,0x98007800 console=tty1 fbcon=map:0 console=ttyS0,115200
bootopts=loglevel=8 initcall_debug=0
abootargs=setenv bootargs board=${board} console=${console} root=${root} fsck.mode=force fsck.repair=yes service=${service} sdmmc_on=${sdmmc_on} ${bootopts}
uenvcmd=run ahello abootargs aload_dtb aload_kernel aload_rootfs aload_audio aboot
```

For the **eMMC** clone, the load-bearing change is `root=UUID=<rootfs-uuid>` (presence-independent;
see §7) in both `uEnv.txt` and `/etc/fstab`.

### `lsblk -f` — disk layout (SD present)

```
NAME          FSTYPE LABEL    MOUNTPOINT
mmcblk0                                        (SD card)
├─mmcblk0p1   vfat   BPI-BOOT /media/pi/BPI-BOOT
└─mmcblk0p2   ext4   BPI-ROOT /
mmcblk1                                        (eMMC)
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

Disk is **29.1 GiB**; the stock image partitions only the first ~7.1 GiB (`growpart` to expand).

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
u-boot-bpi-m4.bin     <- stage-2 U-Boot (the SDR104 culprit, §6)
uEnv.txt
uImage
uInitrd
rtd-1395-bananapi-m4-1GB.dtb
rtd-1395-bananapi-m4-2GB.dtb
bluecore.audio
```

### Two-stage U-Boot banners (diagnostic reference)

```
stage-1:  U-Boot 2015.07 (Feb 25 2020 - ...)   reads SD fine at SDR104
stage-2:  U-Boot 2015.07 (May 18 2020 - ...)   fails SD SDR104 tuning on some card models
```

---

## scripts/

| File | Purpose |
|---|---|
| [`flash.sh`](scripts/flash.sh) | Guarded full-raw `dd` flasher (macOS + Linux), with an `ERASE` confirmation. |
| [`uart-logger.py`](scripts/uart-logger.py) | Tee the 115200 8N1 serial console to stdout + a log file. Autodetects the adapter. |
| [`fix-saved-env.txt`](scripts/fix-saved-env.txt) | Copy-paste U-Boot snippet to reset a genuinely-corrupted saved env (verify with `printenv root` first — see §8). |

---

## License

[MIT](LICENSE).
