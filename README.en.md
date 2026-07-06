# keenetic-entware

[Русский](README.md) · **English**

Prepare a USB flash drive for **Entware** on **Keenetic / Netcraze** routers — in one command, on a bare Mac, without Homebrew, Docker or third-party partitioning apps.

The script partitions the drive (swap + ext4), formats ext4, drops the correct architecture installer onto it, and self-verifies the result. Then you just plug it into the router and enable OPKG.

## Why

macOS can't create ext4 on its own. The usual guides tell you to install Paragon/third-party tools or run Docker. This does it with a single command: it fetches self-contained `mke2fs`/`debugfs` (universal, only depends on `libSystem`), so **nothing needs to be installed** on the Mac.

## Requirements

- macOS (Apple Silicon or Intel)
- A USB flash drive (**everything on it will be erased**)
- Internet on the Mac (to download the installer) and on the router (to install Entware packages)

Homebrew is **not** required. If you already have `e2fsprogs` from Homebrew, the script will use it; otherwise it downloads prebuilt universal binaries from Releases.

## Usage

Run in Terminal:

```
bash <(curl -fsSL https://raw.githubusercontent.com/lastik9/keenetic-entware/main/prepare.sh)
```

The script will:
1. List **removable** drives only and ask you to pick one (with a typed confirmation, so you can't wipe the wrong disk).
2. Ask for your router's CPU architecture (with a model cheat-sheet).
3. Partition, format ext4, write the installer, and verify.

### Dry run (nothing is written)

To see exactly what it would do without touching any disk:

```
DRY_RUN=1 bash <(curl -fsSL https://raw.githubusercontent.com/lastik9/keenetic-entware/main/prepare.sh)
```

### Force the "bare Mac" path (ignore Homebrew)

```
IGNORE_BREW=1 bash <(curl -fsSL https://raw.githubusercontent.com/lastik9/keenetic-entware/main/prepare.sh)
```

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
3. Go to the **OPKG** page → select the **OPKG** drive → **Save**. The router unpacks the installer and downloads the Entware packages from `bin.entware.net` (router needs internet).
4. Watch the **System log** (Diagnostics) for the successful Entware install.

### Router setup (swap + XKeen prep)

After Entware is installed, SSH into the router (login `root`, password `keenetic`, port `222`) and run the helper. A clean Entware has no HTTPS client yet, so first install `wget-ssl`, then fetch the script — **two commands**:

```
opkg update && opkg install wget-ssl ca-bundle ca-certificates
wget -qO- https://raw.githubusercontent.com/lastik9/keenetic-entware/main/router-setup.sh | sh
```

The helper will:
- activate **swap** (`mkswap` + `S02swap` autostart, finding the partition by its `SWAP` label — robust against drive-letter changes);
- run `opkg update` and install base packages (`curl`, `tar`, `nano`, `ca-bundle`);
- check router components (netfilter, IPv6) and tell you what's missing;
- offer to change the `root` SSH password from the default `keenetic`;
- print the [XKeen](https://github.com/jameszeroX/XKeen) install command.

Then reboot the router (`reboot`). Swap comes up automatically; verify with `cat /proc/swaps`.

## Backup and restore

USB flash drives run 24/7 in the router and wear out over time. `backup.sh` takes a **smart image** of a working drive (only the used ext4 blocks — via `e2image`), so when a drive dies you can restore a working Entware/XKeen onto a new drive in a minute instead of setting it up from scratch.

The image is compact: from a 32 GB drive holding ~40 MB of data, the file is ~40 MB (not 32 GB), and it takes seconds.

**Take a backup** (pull the drive from the router, plug it into the Mac):

```
bash <(curl -fsSL https://raw.githubusercontent.com/lastik9/keenetic-entware/main/backup.sh) backup
```

Pick the drive — you get a `keenetic-backup-YYYYMMDD-HHMM.kbak` file in the current folder.

**Restore onto a drive** (a new or different one; it will be erased):

```
bash <(curl -fsSL https://raw.githubusercontent.com/lastik9/keenetic-entware/main/backup.sh) restore keenetic-backup-XXXX.kbak
```

Restore recreates the partition layout, unpacks ext4 from the image and prepares the swap partition. The clone carries everything: Entware, packages, configs, init scripts, SSH keys. After plugging into the router, just activate swap (`router-setup.sh` or `mkswap -L SWAP`).

The target drive must be **at least as large** as the source. Restoring onto a bigger drive also works (ext4 takes the space left after swap).

## How it works

- Partitioning uses the built-in `diskutil`; partition type IDs (0x82 swap, 0x83 Linux) are set with the built-in `fdisk`.
- ext4 is created with `mke2fs`, and the installer is written into the ext4 partition with `debugfs` — **without mounting** (macOS can't mount ext4, and doesn't need to).
- Backup uses `e2image` (used blocks only); restore uses `e2image` to a file + `dd conv=sparse` to the partition.
- The `mke2fs`/`debugfs`/`e2image` binaries are built from e2fsprogs as **universal** (arm64 + x86_64), statically linked internally, so they depend only on `/usr/lib/libSystem`. See [BUILD.md](BUILD.md) to rebuild them yourself.

## Building the binaries yourself

See [BUILD.md](BUILD.md). In short: `bash build-macos-e2fsprogs.sh` downloads the e2fsprogs source, builds a universal bundle, verifies it, and prints the SHA-256.

## Safety

- Only **removable** drives are listed — the system disk can't be selected.
- You must type the exact device name to confirm before anything is erased.
- The downloaded binary bundle is checked against a pinned SHA-256.

## Credits

- [Entware](https://github.com/Entware/Entware) — the package system this prepares a drive for.
- [e2fsprogs](https://github.com/tytso/e2fsprogs) by Theodore Ts'o — `mke2fs` / `debugfs`.
- Community guides by [Corvus-Malus/XKeen](https://github.com/Corvus-Malus/XKeen) and [MaxXxaM/keenetic-entware-flash](https://github.com/MaxXxaM/keenetic-entware-flash).

## License

MIT (this project's scripts). Bundled e2fsprogs binaries are distributed under GPL-2.0 — see [BUILD.md](BUILD.md).
