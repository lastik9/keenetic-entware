# keenetic-entware

[Русский](README.md) · **English**

Prepare a USB flash drive for **Entware** on **Keenetic / Netcraze** routers — in one command, without third-party partitioning apps. **macOS, Windows and Linux** are supported.

The script partitions the drive (swap + ext4), formats ext4, drops the correct architecture installer onto it, and self-verifies the result. Then you just plug it into the router and enable OPKG.

All three platforms produce an **identical** result: an MBR layout with a swap partition (1 GB, type 0x82) and an ext4 partition `OPKG` (type 0x83, the rest), and the installer is written to `/install/<arch>-installer.tar.gz` via `debugfs` — without mounting ext4.

| Platform | Script | How it partitions | Status |
|---|---|---|---|
| **macOS** (Intel/Apple Silicon) | `prepare.sh` | natively (`diskutil` + downloaded `mke2fs`/`debugfs`) | tested on hardware |
| **Linux** (desktop) | `prepare-linux.sh` | natively (`sfdisk` + `e2fsprogs`) | tested |
| **Windows 10/11** | `prepare.ps1` | via WSL2 — runs `prepare-linux.sh` inside | tested |

## Why

Neither macOS nor Windows can create ext4 with built-in tools, and the usual guides send you off to install Paragon, run Docker, or fiddle with partitions by hand. Here it's a single command on each of the three OSes:

- **macOS** — the script downloads self-contained `mke2fs`/`debugfs` (universal, depending only on `libSystem`), so **nothing needs to be installed**.
- **Linux** — native `sfdisk` and `e2fsprogs` are used; anything missing is installed via `apt`.
- **Windows** — all the dirty work moves into **WSL2**: `prepare.ps1` passes the flash drive through and runs the very same `prepare-linux.sh` there. No separate partitioning apps needed.

## Requirements

Common to all platforms:
- A USB flash drive (**everything on it will be erased**)
- Internet on the computer (to download the installer) and on the router (to install Entware packages)

Per platform:
- **macOS** — Apple Silicon or Intel. Homebrew is **not** required: if you already have `e2fsprogs` from Homebrew, the script uses it; otherwise it downloads prebuilt universal binaries from Releases.
- **Linux** — any desktop distro; on Debian/Ubuntu the script installs the missing packages (`e2fsprogs`, `util-linux`, `curl`) itself via `apt`. `sudo` rights required.
- **Windows** — Windows 10/11 x64, virtualization enabled in BIOS/UEFI, and a working **WSL2**. The script requests administrator rights itself (UAC). Everything else (WSL, Ubuntu, and usbipd if needed) it installs automatically.

<details>
<summary>The environment everything was verified on</summary>

The full cycle (prepare → backup → restore → clone → router) was run on:

```
Windows 11 build 26200.8875, PowerShell 5.1.26100.8875
WSL 2.7.10.0, kernel 6.18.33.2-microsoft-standard-WSL2
Ubuntu 26.04 LTS, e2fsprogs 1.47.2
usbipd-win 5.3.0
Keenetic, Entware 2025.05-1, XKeen 2.0 (mihomo, TProxy)
```

Older versions should work too — this is not a requirements list,
just what was actually tested.
</details>

## Preparing the drive

Pick your OS.

### macOS

Run in Terminal:

```
bash <(curl -fsSL https://raw.githubusercontent.com/lastik9/keenetic-entware/main/prepare.sh)
```

The script will:
1. List **removable** drives only and ask you to pick one (with a typed confirmation, so you can't wipe the wrong disk).
2. Ask for your router's CPU architecture (with a model cheat-sheet).
3. Partition, format ext4, write the installer, and verify.

**Dry run** (nothing is written to disk; downloads still happen):

```
DRY_RUN=1 bash <(curl -fsSL https://raw.githubusercontent.com/lastik9/keenetic-entware/main/prepare.sh)
```

**Force the "bare Mac" path** (ignore Homebrew and always download the binaries):

```
IGNORE_BREW=1 bash <(curl -fsSL https://raw.githubusercontent.com/lastik9/keenetic-entware/main/prepare.sh)
```

#### `fdisk` noise on Apple Silicon is not an error

While the partition types are being set, `fdisk` prints:

```
fdisk: could not open MBR file /usr/standalone/i386/boot0
```

It is looking for an Intel-era Mac boot block that does not exist on Apple Silicon. `setpid` (changing a partition type) has no use for that file. `Writing MBR at offset 0.` follows right after, and the script's own self-check confirms types 82/83. **No reason to panic.**

The same stage also normally prints:

```
mke2fs: /dev/... contains a vfat file system labelled 'OPKG'
```

That is expected — the partition has just been created as FAT and is immediately reformatted to ext4; that is exactly why the script passes `-F`.

### Linux

Partitioning needs root, so it's easiest to download the script first and then run it with `sudo`:

```
curl -fsSLO https://raw.githubusercontent.com/lastik9/keenetic-entware/main/prepare-linux.sh
sudo bash prepare-linux.sh
```

With no argument the script lists **removable USB drives only** and asks you to pick one (with a typed confirmation). You can pass the device directly:

```
sudo bash prepare-linux.sh /dev/sdX
```

Environment variables: `DRY_RUN=1` — write nothing to disk; `ARCH=mipsel|mips|aarch64` — skip the architecture menu; `ASSUME_YES=1` — don't ask for device confirmation (for automation). For example:

```
DRY_RUN=1 ARCH=mipsel sudo -E bash prepare-linux.sh /dev/sdX
```

### Windows

> **⚠️ A reboot is required after usbipd is installed.** The flash drive is passed through with `usbipd-win`; on a first-time install its service only starts working after a reboot. The script will notice and tell you.

`prepare.ps1` doesn't partition anything itself: it brings up **WSL2**, passes the flash drive through, and runs `prepare-linux.sh` inside (single source of truth — the same script used on native Linux).

1. Download **two** files into one folder: [`prepare.ps1`](prepare.ps1) and [`prepare-linux.sh`](prepare-linux.sh). (If only `prepare.ps1` is present, it will try to fetch `prepare-linux.sh` from GitHub itself.)
2. Right-click `prepare.ps1` → **"Run with PowerShell"**. Or from a console:

```
powershell -ExecutionPolicy Bypass -File .\prepare.ps1
```

From there the script does everything: requests administrator rights (UAC), installs WSL2 and Ubuntu if needed (`--web-download`, bypassing the Store), checks internet inside WSL (and offers to set a public DNS **inside WSL only**, if it's intercepted by a VPN/proxy), passes the flash drive into WSL, asks for architecture and drive (confirm by typing `YES`), runs the partitioning, and correctly returns the drive to the system when done.

**The passthrough uses `usbipd-win` — identically on Windows 10 and Windows 11.** The script installs it via `winget` automatically and detects the right USB device by VID:PID (if it can't, it shows the list and asks you to enter the BUSID). The native `wsl --mount` does not work for removable USB drives (see [below](#why-wsl---mount-is-no-good-for-flash-drives)), so for flash drives it isn't even attempted.

> **⚠️ Don't run it through `| Tee-Object`.** The pipe re-encodes the output a second time in the outer PowerShell and mangles non-ASCII text, no matter what encoding settings are in place. If you need a log, use `Start-Transcript`.

Optional parameters: `-Arch mipsel|mips|aarch64` — skip the menu; `-DryRun` — dry run (nothing is written to the disk, but you still pick the drive and confirm); `-KeepWslDns` — don't touch WSL DNS; `-LinuxScript <path>` — use a specific `prepare-linux.sh`.

### Why `wsl --mount` is no good for flash drives

`wsl --mount --bare \\.\PHYSICALDRIVE<N>` is the built-in Windows 11 way to hand a physical disk to WSL2 without third-party tools. For **removable** USB drives it fails consistently:

```
Wsl/Service/AttachDisk/MountDisk/HCS/0x8007000f   (ERROR_INVALID_DRIVE)
```

Reproduced on Windows 11 build 26200 with different flash drives. The command is designed for non-removable physical disks and won't take removable media. That's why the project's scripts check whether the disk is removable (`Win32_DiskDrive.MediaType`) and go straight to `usbipd-win` for flash drives instead of wasting time on an attempt that's certain to fail.

### If WSL isn't installed

```powershell
wsl --install -d Ubuntu --web-download
```

Reboot, then wait for Ubuntu's first-run setup (UNIX login/password). On a healthy system this takes under a minute plus one reboot. You don't need internet inside WSL: the Ubuntu image already ships `e2fsprogs` and `util-linux`.

#### If the install hangs

`wsl --install` runs through **DISM**, and on a damaged Windows it hangs dead: the spinner sits still, the CPU is idle. To tell "slow" from "hung":

```powershell
Get-Item C:\Windows\Logs\DISM\dism.log | Select-Object LastWriteTime
```

Run it twice a minute apart. The timestamp moves — work is happening, keep waiting. It doesn't move for 5+ minutes — it's hung.

**Don't interrupt DISM halfway** — reboot instead; components often finish applying during boot.

#### Diagnostics

```powershell
# Features (this is a flag, not a fact!)
Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform | Select FeatureName, State
Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux | Select FeatureName, State

# Hypervisor and BIOS virtualization
Get-ComputerInfo -Property HyperVisorPresent, HyperVRequirementVirtualizationFirmwareEnabled

# The key check: the service must exist
Get-Service vmcompute | Select Name, Status, StartType
```

Worth knowing:

- **`wsl --status` lies.** It prints "virtualization is not enabled" whenever the VM fails to start — even when virtualization is perfectly fine. Don't trust the text, look at `vmcompute`.
- **`VirtualMachinePlatform = Enabled` means nothing on its own.** If the `vmcompute` service is missing at the same time, the feature is listed as enabled but was never actually deployed. That's a sign of a corrupted Windows component store (WinSxS).
- **`vmcompute` sitting at `Stopped / Manual` is normal** — the service starts on demand.

#### Workarounds

```powershell
# 1. Features one at a time — they go through more readily than wsl --install in one go
dism /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
# then reboot

# 2. Hypervisor doesn't start (HyperVisorPresent: False while BIOS virtualization is True)
bcdedit /enum {current} | findstr /i hypervisorlaunchtype
bcdedit /set hypervisorlaunchtype auto
# then reboot

# 3. The WSL2 kernel directly, bypassing DISM:
#    download wsl.<version>.x64.msi from https://github.com/microsoft/WSL/releases/latest
#    install with a double-click, reboot
wsl --version   # prints versions if the engine came up
```

If DISM **and** `sfc /scannow` both hang while the disk is healthy, the Windows component store is corrupted. Fix it with `dism /online /cleanup-image /restorehealth` (needs internet) or by reinstalling. Digging further is pointless: this isn't "slow", it's a broken Windows.

## Architecture cheat-sheet

| Archive | Keenetic / Netcraze models |
|---|---|
| **mipsel** | Giga (KN-1010/1011), Ultra (KN-1810), Extra (KN-1710/1711/1713), Omni (KN-1410), Viva (KN-1910/1912/1913), Giant (KN-2610), Hero 4G (KN-2310/2311), Hopper (KN-3810), 4G (KN-1212); Zyxel Keenetic II/III, Extra, Giga II/III, Omni, Viva, Ultra and similar |
| **mips** | Ultra SE (KN-2510), Giga SE (KN-2410), DSL (KN-2010), Skipper DSL (KN-2112), Duo (KN-2110), Hopper DSL (KN-3610); Zyxel Keenetic DSL, LTE, VOX |
| **aarch64** | Peak (KN-2710), Ultra (KN-1811 / NC-1812), Giga (KN-1012), Hopper (KN-3811), Hopper SE (KN-3812) |

If unsure, check your model on the sticker or in the router's web interface.

## On the router

After the drive is ready:

1. Plug the flash drive into the Keenetic.
2. Web interface → **General settings** → enable the components **OPKG (open package support)** and **Ext filesystem**.
3. Go to the **OPKG** page → select the **OPKG** drive → **Save**. The router unpacks `install/<arch>-installer.tar.gz` and downloads the Entware packages from `bin.entware.net` (router needs internet).
4. Watch the **System log** (Diagnostics) for the successful Entware install.

> **Important: reboot the router when swapping drives.** If you pull one drive and insert another, always reboot the router before installing. Otherwise the router keeps traces of the previous drive (disk letters, stale OPKG config) and the install may fail with `exec format error` in the log. Simple rule: **one drive + reboot = clean start.**

> **If you see `exec format error`** (Entware "installs" but won't start / SSH won't let you in): reboot the router with a single drive inserted — this almost always fixes it. If the error persists on a specific drive, verify the architecture: on a working install, `opkg print-architecture` shows the real arch (e.g. `mipsel-3.4`). Don't rely on `show version` from the web CLI — it reports the arch in a broad sense (`mips` for mipsel systems) and is misleading. Note also that **Netcraze (NC-XXXX)** is a separate Keenetic brand: identically named models (e.g. Viva) may have a different arch, so `opkg print-architecture` is the most reliable source.

## Two SSH servers: port 222 and port 22

A router with Entware runs **two independent SSH servers**, and it's important to understand this:

| | port **222** | port **22** |
|---|---|---|
| What it is | `dropbear` from Entware (`/opt/sbin/dropbear`) | the built-in Keenetic SSH (`/usr/sbin/dropbear`) |
| Where it lives | on the flash drive (`/opt`) | in the router firmware |
| Login | `root`, default password `keenetic` | **the web-panel user** (usually `admin`) |
| Where you land | straight into a BusyBox shell | the Keenetic CLI — then run `exec sh` |

**Port 22 is the emergency entrance.** Don't disable the router's built-in SSH server: if the Entware dropbear on 222 didn't come up (the drive didn't mount, a package updated, a stale pid file), this is the only way to reach the router over SSH:

```
ssh -p 22 admin@192.168.10.1      # login/password as in the web panel
exec sh                            # drop from the Keenetic CLI into BusyBox
```

Note: the built-in SSH on 22 **won't accept `root`** with any password — it doesn't know that user. `root`/`keenetic` is the account for the Entware dropbear on 222 only.

### `Connection refused` on port 222 after a reboot

Symptom: after a reboot `ssh -p 222` gives `Connection refused`, but if you log in via port 22 and run `/opt/etc/init.d/S51dropbear start`, SSH works immediately. And so every time.

The cause is a **bug in the dropbear package's init script** from Entware. The stock `S51dropbear` decides the daemon is alive using:

```sh
[ -f $PIDFILE ] && [ -d /proc/`cat $PIDFILE` ]
```

that is, it only checks whether the directory `/proc/<PID>` **exists**, without verifying **whose** process it is. The pid file itself (`/opt/var/run/dropbear.pid`) lives on the ext4 flash drive and **survives a reboot**. After the reboot its number is taken by a different process (on Netcraze it's `tsmb-server` — the built-in SMB server), the script decides "already running", silently exits — and nothing listens on 222. Rebooting doesn't help: the pid file is the same every time.

Check it on your router (via port 22 → `exec sh`):

```sh
cat /opt/var/run/dropbear.pid                       # e.g. 634
ps w | grep '[/]opt/sbin/dropbear'                  # empty — no daemon
cat /proc/$(cat /opt/var/run/dropbear.pid)/comm     # tsmb-server — there's the culprit
```

**The fix** is option **4** in the `router-setup.sh` menu ("SSH-222 fix only"). It replaces `dropbear_status` with a check on `/proc/<PID>/comm` (the process really is `dropbear`) and removes the stale pid file before starting. The original is saved as `S51dropbear.bak`. The patch is also applied automatically in mode **1** (full setup).

> **After `opkg upgrade dropbear` the patch is overwritten** — the package installs its own init script. Run option 4 again.

The ready-made file is in the repository: [`S51dropbear`](S51dropbear).

### Router setup (swap + XKeen prep)

After Entware is installed, SSH into the router (login `root`, password `keenetic`, port `222`) and run the helper. A clean Entware has no HTTPS client yet, so first install `wget-ssl`, then fetch the script — **two commands**:

```
opkg update && opkg install wget-ssl ca-bundle ca-certificates
wget -T 15 -t 3 -qO- \
  https://raw.githubusercontent.com/lastik9/keenetic-entware/main/router-setup.sh | sh
```

The helper shows a **menu** of four scenarios:

1. **Full setup** — activates **swap** (`mkswap` + `S02swap` autostart, finding the partition by its `SWAP` label, robust against drive-letter changes), runs `opkg update` and installs base packages (`curl`, `tar`, `nano`, `vim`, `ca-bundle`), checks router components (netfilter, IPv6), applies the `S51dropbear` fix, offers to change the SSH password, and **immediately launches the [XKeen](https://github.com/jameszeroX/XKeen) installer** (GitHub, with a jsDelivr mirror fallback).
2. **Install XKeen only** — if Entware and swap are already set up and you only need the proxy. Same GitHub → jsDelivr fallback.
3. **Swap only** — the quick path after restoring a drive from a backup: checks and enables swap (with human-readable diagnostics and size) and sets up autostart, without reinstalling anything else.
4. **SSH-222 fix only** — fixes the stale dropbear pid file (see the section above). Handy after `opkg upgrade dropbear`.

After setup, reboot the router (`reboot`). Swap comes up automatically; verify with `cat /proc/swaps`.

#### "No partition labelled SWAP" on a fresh drive is normal

On its first run the helper will almost certainly warn that it found no partition labelled `SWAP` and is falling back to the partition table.

That is by design. `prepare.sh` creates the swap partition as FAT32 named `SWAP`, but then **zeroes out the first 8 MB** so the router won't mistake the partition for VFAT. The volume label dies together with the FAT signature, so on a fresh drive `blkid` sees no `LABEL="SWAP"`.

The helper then locates the partition by its 0x82 type and runs `mkswap -L SWAP` — and the label appears. From the second run on, the lookup by label works. Nothing needs fixing.

#### Hot-swapping the drive: reboot the router

If the drive was pulled and plugged back in **without a reboot**, it may come up under a different letter (`sda` → `sdb`). The `S02swap` autostart survives that — it looks the partition up by label, not by device name — but `/proc/swaps` keeps an entry for the old device:

```
/dev/sda1\040(deleted)   partition   999996   80   -1
/dev/sdb1                partition   999996    0   -2
```

The top line is a phantom: the device is gone, yet the kernel still counts swap on it — **and at a higher priority** (`-1` against `-2`). While there is enough RAM this is harmless, but the moment swap is actually needed the kernel will reach for a device that no longer exists.

Cured by a reboot (`reboot`). Afterwards `/proc/swaps` should hold **one** line, with no `(deleted)` marker.

### Geodata for XKeen/Mihomo (if the databases won't download)

On start, XKeen/Mihomo downloads `geoip`/`geosite`/`mmdb` databases from GitHub (release assets). From some networks (e.g. in Russia) GitHub may be unreachable — you'll see a TLS timeout in the logs, and the proxy won't come up without the databases:

```
ERRO can't initial ASN: can't download ASN.mmdb: net/http: TLS handshake timeout
FATA Parse config error: rules[121] [IP-ASN,16509,PROXY] error: ...
```

The fix is to point at mirrors via the **jsDelivr** CDN in the Mihomo config (`/opt/etc/mihomo/config.yaml`):

```yaml
geox-url:
  geoip: "https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat"
  geosite: "https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat"
  mmdb: "https://fastly.jsdelivr.net/gh/P3TERX/GeoLite.mmdb@download/GeoLite2-Country.mmdb"
  asn: "https://fastly.jsdelivr.net/gh/P3TERX/GeoLite.mmdb@download/GeoLite2-ASN.mmdb"
```

After editing, restart XKeen/Mihomo — the databases will pull from the mirror.

### "XKeen starts slowly" — it's not the flash drive

The line `Initial configuration complete, total time: 47179ms` (sometimes 100+ seconds) is scary, but **drive wear, swap, and this project's scripts have nothing to do with it**. On start Mihomo parses geodata into memory, and the fattest chunk is the `category-ads-all => REJECT` rule (over 160,000 entries). This is **pure CPU load**, and Keenetic/Netcraze routers on the MT7621A have only 880 MHz. Different runs on the same disk give different times — which means it's not I/O.

Measurements on live hardware (Netcraze Viva, 64 GB USB 2.0, XKeen running):

```
dd if=/dev/sda2 of=/dev/null bs=1M count=200   →  ~37 MB/s (USB 2.0 ceiling)
free                                            →  swap used = 0, ~120 MB RAM free
```

The drive reads at the bus limit and swap isn't used at all. Want a faster start? Remove heavy rules from the Mihomo config rather than changing the drive.

## Editing configs over the network (SMB), without SSH

You don't have to dive into the terminal to tweak Mihomo's `config.yaml`. The `/opt` partition on the flash drive can be **opened as an ordinary network share** — in Finder or File Explorer — and files edited with a double-click.

You **don't** need to install Samba from Entware for this: Keenetic/Netcraze already has a built-in SMB server (`tsmb-server`). You just need to set up the share correctly.

### Setup (web panel)

Open **Applications → SMB server**:

1. **Delete dead shares.** If entries have "Folder not found" in red beneath them, those are traces of previous drives and they get in the way of creating a working share. In the router log they show up as:
   ```
   [E] Cifs::ServerTsmb: share record "OPKG" already exists.
   [W] Cifs::ServerTsmb: failed to automount "<UUID>", ignored.
   ```
   Delete all such entries with the trash icon. A share for the `SWAP` partition isn't needed either — it's not a filesystem.

   > Where they come from: on every drive preparation `diskutil` first creates the partitions as FAT32, and the router remembers their short serials (`45D2-1B0A`). Swap the drive — the old record stays. See the full list in the CLI (`ssh -p 22 admin@<ip>`) with `show running-config`, the `cifs` section.

2. **Uncheck "Anonymous access".** In anonymous mode (`cifs permissive` in the config) the server doesn't check accounts, and logging in as `admin` is rejected with `Authentication error`. It's also a hole: `/opt` — the Entware root with configs, init scripts and SSH keys — becomes accessible to anyone on the LAN without a password.

3. **Add a share** with the "+ Add share" button, pointing to the currently mounted `OPKG` partition. Verify it's mounted in **Applications → Disks and printers** (status "Connected", filesystem `EXT4`).

4. Make sure the user has the **"SMB network shares"** permission: **Management → Users → admin**.

### Connecting

**Finder (macOS):** `Cmd+K` → `smb://192.168.10.1` → web-panel login and password.
**File Explorer (Windows):** type `\\192.168.10.1` in the address bar.

The Mihomo config will be at `etc/mihomo/config.yaml` inside the share.

The same from a terminal:

```
smbutil view //admin@192.168.10.1                       # list of shares: OPKG should be there
mkdir -p ~/smb-opkg
mount_smbfs //admin@192.168.10.1/OPKG ~/smb-opkg        # mount
ls ~/smb-opkg/etc/mihomo/
umount ~/smb-opkg                                       # unmount
```

> **Guest login won't help.** Modern macOS refuses anonymous SMB connections, and a server in `permissive` mode shows a guest only the service `IPC$` without a single file share. What works is exactly "anonymous access off + log in as `admin`".

### Care when editing

- Before changing anything, make a copy alongside: `config.yaml.bak`. Rolling back is easier than hunting for an indentation error in YAML on the router.
- Don't touch `cache.db` and the `*.dat`/`*.mmdb` databases over the network — mihomo keeps them open.
- After editing, restart the proxy: `xkeen -restart`.

## Backup and restore

USB flash drives run 24/7 in the router and wear out over time. The backup scripts take a **smart image** of a working drive (only the used ext4 blocks — via `e2image`), so when a drive dies you can restore a working Entware/XKeen onto a new drive in a minute instead of setting it up from scratch.

Available on **all three OSes**:

| Task | macOS | Linux (native) | Windows 10/11 |
|---|---|---|---|
| Prepare the drive | `prepare.sh` | `prepare-linux.sh` | `prepare.ps1` |
| Backup / restore / clone | `backup.sh` | `backup-linux.sh` | `backup.ps1` |
| Router setup | `router-setup.sh` — over SSH from any OS | | |

The `.kbak` format is **the same on all three** — an image taken on a Mac restores on Windows and vice versa.

The image is compact: from a 64 GB drive holding ~1.1 GB of data, the file is ~53–75 MB (not 64 GB), and it takes seconds.

All three scripts offer the same three modes, all available from a **menu** (run with no arguments):
- **backup** — take an image of the drive into a `.kbak` file;
- **restore** — write an image to a drive (the script shows the list of found `.kbak` files, no typing needed);
- **clone** — take an image from one drive and write it straight to another (no intermediate file name).

Restore recreates the partition layout, unpacks ext4 from the image, grows the FS to the whole partition, and prepares the swap partition. The clone carries everything: Entware, packages, configs, init scripts, SSH keys.

### macOS

One command — a menu appears:

```
bash <(curl -fsSL https://raw.githubusercontent.com/lastik9/keenetic-entware/main/backup.sh)
```

If you want a specific mode, download the script:

```
curl -fsSLO https://raw.githubusercontent.com/lastik9/keenetic-entware/main/backup.sh
```

and run **one** of these:

- `bash backup.sh` — menu
- `bash backup.sh backup` — take an image into a `.kbak` file
- `bash backup.sh restore` — restore an image onto a drive (**the drive gets erased**)
- `bash backup.sh clone` — take an image and write it straight to another drive

In `restore` mode you can name the file up front, otherwise the script shows a picker menu:
`bash backup.sh restore keenetic-backup-XXXX.kbak`

### Linux (native)

```
curl -fsSLO https://raw.githubusercontent.com/lastik9/keenetic-entware/main/backup-linux.sh
chmod +x backup-linux.sh
```

Then run **one** of these:

- `./backup-linux.sh` — menu: backup / restore / clone
- `./backup-linux.sh backup` — take an image into a `.kbak` file
- `./backup-linux.sh restore` — write an image to a drive (**the drive gets erased**)
- `./backup-linux.sh clone` — take an image and write it straight to another drive

The script elevates itself with `sudo` and installs `e2fsprogs`/`util-linux` via `apt` if they're missing. Nothing else is needed — no binaries are downloaded, everything comes from the distro repositories.

Environment variables: `DEV=/dev/sdX` — name the device up front and skip the interactive picker; `DRY_RUN=1` — write nothing to disk; `NO_SHRINK=1` — don't shrink the FS before imaging; `KBAK_OUT=<path>` — where to put the `.kbak`.

### Windows 10 / 11

You'll need: **WSL2 with Ubuntu**, administrator rights, and `usbipd-win` (installed automatically). If you don't have WSL yet, see ["If WSL isn't installed"](#if-wsl-isnt-installed).

Put [`backup.ps1`](backup.ps1) and [`backup-linux.sh`](backup-linux.sh) **in the same folder**, open PowerShell **as administrator**, and run:

```
cd "path\to\folder"
powershell -ExecutionPolicy Bypass -File .\backup.ps1
```

Running it with no parameters gives you a menu. Otherwise, **one** of these:

- `.\backup.ps1 -Mode backup` — take an image of the drive into a `.kbak` file
- `.\backup.ps1 -Mode restore` — write an image to a drive (**the drive gets erased**)
- `.\backup.ps1 -Mode clone` — take an image and write it straight to another drive
- `.\backup.ps1 -Mode backup -DryRun` — dry run, nothing is written to disk

`backup.ps1` is a thin wrapper: it checks WSL, delivers `backup-linux.sh` into Ubuntu, passes the flash drive through with `usbipd-win`, and all the disk work is done by that same `backup-linux.sh` used on native Linux.

> **⚠️ Don't run it through `| Tee-Object`** — the pipe mangles the encoding. If you need a log, use `Start-Transcript`.

**First run:** `usbipd-win` will be installed (via `winget`). After it installs, a **reboot is mandatory** — its service doesn't work until then. The script will tell you.

With `-Mode backup` the finished `.kbak` is placed **next to the script** (change it with `-OutDir <path>`). `C:\Temp` (`/mnt/c/Temp` from inside WSL) is only a staging area on the way: a path with no spaces or non-ASCII characters works the same whatever the Windows user name is. With `-Mode clone` the image stays in `C:\Temp` — the script prints the full path; it is a ready backup of the source, and it is up to you whether to keep it.

On Windows the `clone` mode is orchestrated by the wrapper itself, because WSL can only hold one disk attached at a time: image the source → detach → attach the target → restore.

**One USB port is enough.** The phases are decoupled by the file: the image is written to `C:\Temp` first, so the source is no longer needed — the script will ask you to unplug it and insert the target drive. Two ports work too; just don't mix the drives up when picking the target.

> **⚠️ A clone carries the filesystem UUID as well** — it is identical to the source drive. The router mounts `/opt` by UUID, so **never plug both drives into the router at once**: which one becomes `/opt` is unpredictable. Keep the clone as a backup, not as a second working drive.

> **After a restore, be sure to enable swap on the router** — otherwise XKeen will crash. See ["After a restore XKeen crashes with out of memory"](#after-a-restore-xkeen-crashes-with-out-of-memory).

### FS shrink during backup

Before taking the image the script **temporarily shrinks** ext4 to the real data size (`resize2fs`), takes the image, and **immediately grows the FS back** to the whole partition. The source drive is left exactly as it was.

Why: on restore `dd` writes the image up to the FS boundary. If the FS occupies the whole partition, `dd` honestly pours tens of gigabytes, almost all of them zeros.

Real numbers from a 64 GB drive (~1.1 GB of data):

| | without shrink | with shrink |
|---|---|---|
| FS in the image | 56.3 GiB | **512 MB** |
| what `dd` writes | 56.3 GiB | **512 MB** |
| `.kbak` file | 75 MB | 53 MB |

Writing shrinks **113×**. The `.kbak` file was already compact (`e2image` copies only used blocks) — the bottleneck was always the restore.

Shrink is on by default and only happens if `e2fsck` confirmed the FS is clean. Disable it:

```
NO_SHRINK=1 ./backup.sh backup
```

If something goes wrong during backup (Ctrl-C, drive yanked), the script traps the exit and grows the FS back. If even that fails — the data is intact, the FS is simply smaller than the partition; the script prints the command for a manual restore.

### Cloning onto a smaller drive

With shrink this became possible: what matters is not the source drive's size but **whether the data fits** the target partition. A system from a 64 GB drive with 1.1 GB used can be deployed onto a 16 GB one — the FS then grows to the new size. Works on **all three OSes**.

Verified on a live router: an image taken from a 32 GB drive on Windows was restored onto 16 GB — the Keenetic brought up Entware, swap and XKeen with no adjustments.

The script warns that the target drive is smaller and checks capacity. For **old** images (taken before shrink existed) the old rule holds: the target drive must be no smaller than the source.

### After a restore XKeen crashes with out of memory

Restore wipes the swap partition, and the `SWAP` label along with its signature disappears. A fresh drive has no swap. A router with 256 MB RAM runs out exactly while parsing `category-ads-all` (164 thousand rules), and `mihomo` crashes:

```
INFO Load GeoSite rule: category-ads-all
fatal error: runtime: out of memory
```

This is **not image corruption**. It's fixed with one command on the router — option **3) Swap only** in `router-setup.sh`:

```
wget -T 15 -t 3 -O /tmp/rs.sh \
  https://raw.githubusercontent.com/lastik9/keenetic-entware/main/router-setup.sh
sh /tmp/rs.sh
```

The script finds the swap partition by the layout (the label is gone), sets the label and signature, enables swap, and registers autostart. Verify:

```
free | grep Swap
cat /proc/swaps
```

Then `xkeen -restart` — the start takes about a minute and a half, which is normal.

### FS check before taking an image

Before `e2image` the script runs `e2fsck -fn` (read-only, changes nothing). If the drive was pulled from the router without unmounting, the ext4 journal stays "dirty", and `e2image` can fail:

```
e2image: Can't read next inode while getting next inode
```

Worse if the image is taken silently — it would carry garbage. So on a dirty FS the script shows the `e2fsck` output and offers: `[f]` fix (`e2fsck -fy`), `[c]` continue as is, `[q]` quit.

If you pick `[c]`, the FS shrink is skipped: `resize2fs` won't work on an unverified FS, and rightly so.

**About the ext4 journal.** If the drive was pulled from a router that was writing to it up to the last second, `e2fsck -fn` will say:

```
Warning: skipping journal recovery because doing a read-only filesystem check.
```

There are uncommitted transactions left in the journal. This is normal, not damage. A fix (`-fy`) replays the journal, and **the file count may change slightly** — e.g. a deferred deletion of temp files gets applied. That's expected.

**About the exit code.** For `e2fsck` the exit code is a **bit mask**, not "zero is good, anything else is bad":

| Code | Meaning |
|---|---|
| `0` | no errors found |
| `1` | errors found and **corrected** — the normal outcome of a repair |
| `2` | corrected, asks for a reboot (irrelevant for a removable drive) |
| `4` | some errors were **left** uncorrected |
| `8` / `16` / `32` | operational error / syntax / cancelled by the user |

So after a successful repair the script prints a **green** line stating that errors were found and corrected, quoting the code (`1` is the norm here). A yellow warning about the exit code shows up only at `4` and above — that is when there is something to worry about. Either way the decisive line is the next one: the script re-checks the FS and should report it clean. If it did, the image is taken from a healthy filesystem.

> Before the K-2 fix the script warned on **any** non-zero code, so a yellow line flashed by after every successful repair. If you still see that, you are on an older version of the script — and there is still nothing to worry about.

On top of that, once the journal has been replayed **the number of used blocks usually grows**: data that was sitting in the journal goes back into place. That is the journal doing its job, not a loss.

### Where to get the full path to a `.kbak`

If the file is not next to the script and not in `~/keenetic`, autodiscovery won't find it — you need the **full path**, e.g.:

```
/Users/<user>/Desktop/keenetic-backup-20260709-0226.kbak
```

You don't have to type it by hand: **drag the file from Finder straight into the Terminal window** — the path is inserted for you. Or `cd` into the folder and check `pwd`.

### Growing the FS to the full size of a new drive

Done **automatically**: after `dd` the script runs `e2fsck -fy` and `resize2fs`, and the FS takes the whole target partition. Nothing to finish by hand — the script says so at the end.

The final size is a bit under nominal: e.g. a 60.5 GB partition yields ~55 GB. That's normal — ext4 metadata plus the 5% reserve for `root`.

If `resize2fs` is unavailable (an old bundle without it, and no Homebrew), the script honestly warns and leaves the FS at its original size. Then grow it manually **on the router**, always **`e2fsck -f` first**:

```
opkg install e2fsprogs resize2fs
DEV=$(blkid | grep 'LABEL="OPKG"' | cut -d: -f1)
e2fsck -f "$DEV" && resize2fs "$DEV"
```

(the `OPKG` partition is found by label — just like swap by the `SWAP` label.)

## How it works

**Partitioning (identical result on all OSes):**
- **macOS** — partitioning with the built-in `diskutil`; partition type IDs (0x82 swap, 0x83 Linux) are set with the built-in `fdisk`.
- **Linux / Windows(WSL)** — partitioning and type IDs in a single `sfdisk` call; old signatures are wiped with `wipefs`.
- On all platforms ext4 is created with `mke2fs -F -t ext4 -L OPKG -O ^64bit,^metadata_csum`, and the installer is written into the ext4 partition with `debugfs` — **without mounting** (ext4 doesn't need mounting, and macOS can't do it anyway).
- The **swap partition is not formatted** by the preparation script: `mkswap` and activation are done by `router-setup.sh` on the router (by the `SWAP` label). The script only wipes the FAT signature off it, so the router doesn't mistake it for VFAT.
- **Windows** partitions nothing itself: `prepare.ps1` passes the physical disk into WSL2 via `usbipd-win` (`wsl --mount` doesn't work for removable media) and runs `prepare-linux.sh` there.

**Backup/restore:**
- Backup uses `e2image` (used blocks only). Shrinking the FS before backup is safe and shortens the write at the **FS boundary** — which is fundamentally not the same as `sparse`.
- The `.kbak` format is a plain `tar.gz` of three files: `mbr.bin` (the layout), `opkg.e2img` (the FS image) and `meta.txt` (metadata, including the shrunk FS size). **Identical across all three OSes** — an image taken on a Mac restores on Linux and Windows, and vice versa.
- **On Linux/WSL `e2image -ra` writes straight into the block device** — no intermediate file needed. Partitioning is a single `sfdisk` call (`,1024M,82` / `,,83`), bit-for-bit the same layout as `prepare-linux.sh`. Tools come from `e2fsprogs`/`util-linux` via `apt` — no downloaded bundles.
- **On macOS** `e2image` **can't write to a raw device** (`/dev/rdiskNsX`) — it returns `block -1`. So restore first expands the image into a file the size of the FS, then writes that file to the partition via `dd` **in full, without** `conv=sparse` — skipping zero blocks would leave garbage from the old layout in their place and corrupt the FS.
- The ext4 partition is found by the `OPKG` label (`blkid`) on Linux/Windows, with a fallback to the second partition; on macOS it's hard-wired to the second partition.
- None of the scripts run `mkswap`: the swap partition is only wiped, and the signature and label are written by `router-setup.sh` on the router.
- `resize2fs`, unlike `e2image`, works with the macOS **block** device (`/dev/diskNsX`) without complaints.
- The shrunk FS size is taken **from `resize2fs` output**, not from a calculation: it rounds the requested size down to a block-group boundary (e.g. ask for 131550 blocks, get 131072). Writing the calculated number into metadata would under-write the tail during `dd` and quietly corrupt the FS.
- `resize2fs -P` (minimum size) systematically underestimates, so the script keeps a margin: `+30%`, but no less than `+8192` blocks.
- The shrunk FS is often **smaller than the "used" size** — because empty block groups collapse together with their inode tables. On a 64 GB drive the tables alone took 942 MB.
- `e2fsck` on macOS works through the **block** device (`/dev/diskNsX`), not through `rdisk`. Check a finished clone manually:
  ```
  diskutil unmountDisk force /dev/diskN
  sudo e2fsck -fn /dev/diskNs2 | tail -15
  ```
  A healthy result is 5 passes with no `Fix?` or `illegal block` lines, ending with `OPKG: NNNN/... files`.
- The macOS `mke2fs`/`debugfs`/`e2image` binaries are built from e2fsprogs as **universal** (arm64 + x86_64), statically linked internally, so they depend only on `/usr/lib/libSystem`. See [BUILD.md](BUILD.md) to rebuild them yourself. On Linux and Windows nothing needs downloading.
- `e2fsck` and `resize2fs` are included in the downloaded macOS bundle as well (together with `mke2fs`, `debugfs` and `e2image`), so the FS pre-check and shrink work on a bare Mac without Homebrew. If Homebrew's `e2fsprogs` is present the script prefers it; otherwise it falls back to the bundled tools. Only an older bundle that predates these binaries skips the check and shrink.

## Building the binaries yourself

See [BUILD.md](BUILD.md). In short: `bash build-macos-e2fsprogs.sh` downloads the e2fsprogs source, builds a universal bundle, verifies it, and prints the SHA-256.

## Safety

- Only **removable** drives are listed — the system disk can't be selected.
- You must type the exact device name (or `YES` on Windows) to confirm before anything is erased.
- The downloaded binary bundle (macOS only) is checked against a pinned SHA-256. On Linux and Windows the tools come from the distro repositories, so there's nothing to download.
- Change the default SSH password (`passwd root`) — `router-setup.sh` offers this itself.

## Credits

- [Entware](https://github.com/Entware/Entware) — the package system this prepares a drive for.
- [e2fsprogs](https://github.com/tytso/e2fsprogs) by Theodore Ts'o — `mke2fs` / `debugfs`.
- Community guides by [Corvus-Malus/XKeen](https://github.com/Corvus-Malus/XKeen) and [MaxXxaM/keenetic-entware-flash](https://github.com/MaxXxaM/keenetic-entware-flash).

## License

MIT (this project's scripts). Bundled e2fsprogs binaries are distributed under GPL-2.0 — see [BUILD.md](BUILD.md).
