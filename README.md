# adb-hide-susfs

<p align="center">
  <a href="https://github.com/ymuuuu/adb-hide-susfs/releases/latest"><img src="https://img.shields.io/github/v/release/ymuuuu/adb-hide-susfs?style=flat&color=0969DA" alt="Latest release" /></a>
  <a href="https://github.com/ymuuuu/adb-hide-susfs/releases"><img src="https://img.shields.io/github/downloads/ymuuuu/adb-hide-susfs/total?style=flat&color=8957E5" alt="Total downloads across all releases" /></a>
  <a href="https://github.com/ymuuuu/adb-hide-susfs/stargazers"><img src="https://img.shields.io/github/stars/ymuuuu/adb-hide-susfs?style=flat&label=%E2%98%85&color=E3B341" alt="GitHub stars" /></a>
  <img src="https://img.shields.io/badge/license-AGPL--3.0-F0883E?style=flat" alt="License: AGPL-3.0" />
  <img src="https://img.shields.io/badge/Android%20arm64%20%7C%20x86__64-KernelSU%20Next-3DDC84?style=flat&logo=android&logoColor=white" alt="Platform: Android arm64 and x86_64, KernelSU Next" />
  <a href="https://t.me/ymuulabs"><img src="https://img.shields.io/badge/Telegram-26A5E4?style=flat&logo=telegram&logoColor=white" alt="Telegram channel" /></a>
  <a href="https://x.com/ymuuu_"><img src="https://img.shields.io/badge/X-000000?style=flat&logo=x&logoColor=white" alt="Follow on X" /></a>
  <a href="https://paypal.me/ymuu"><img src="https://img.shields.io/badge/PayPal-003087?style=flat&logo=paypal&logoColor=white" alt="Support me on PayPal" /></a>
</p>

Hides that ADB is on from Android apps, while your real adb session keeps working.

A KernelSU module. It spoofs the ADB runtime properties with `resetprop`, and with a
patched susfs kernel module it also hides the two sockets adbd exposes to apps. The
property logic is the ADB subset of [BRENE](https://github.com/rrr333nnn333/BRENE)
by rrr333nnn333.

Releases and updates are announced on Telegram: [t.me/ymuulabs](https://t.me/ymuulabs).

---

## Tested status

| Device | Result |
|---|---|
| Pixel 6a, Android 15, KernelSU Next, susfs LKM fork + HMA-OSS fix | Duck Detector's ADB Runtime card reads "ADB state consistent": init socket absent, JDWP connection refused, USB no functions, no contradiction. |
| Pixel 6a, same, with KernelSU Next's bundled susfs LKM | No contradiction, but Duck still reports ADB as active (WARNING), because the sockets stay visible. |
| Pixel 9 x86_64 AVD, Android 16 | Property side and the vsock-only mode tested (v1.2.0). The socket hiding in v1.3.0 is not tested there yet. |
| Everything else | Untested. |

The detector used throughout is [Duck Detector](https://github.com/eltavine/Duck-Detector-Refactoring).

---

## What it hides

Duck Detector decides "ADB enabled" from an OR of several sources, and flags a HIGH
"runtime contradiction" when one source says stopped and another can prove adbd runs.
Each source needs its own fix:

| Source an app reads | Fixed by |
|---|---|
| `Settings.Global` `adb_enabled`, `adb_wifi_enabled` | HMA-OSS `hide_adb` |
| `USB_STATE` sticky broadcast, `adb` extra | HMA-OSS `BroadcastHook` (on Android 15 builds that already use `BroadcastController`, needs the fix in [ymuuuu/HMA-OSS](https://github.com/ymuuuu/HMA-OSS) branch `fix/usb-state-broadcast-controller`) |
| `init.svc.adbd`, `init.svc_debug_pid.adbd` | this module: `stopped`, empty |
| `sys.usb.state`, `sys.usb.config`, `persist.sys.usb.config` | this module: `mtp` |
| `service.adb.root`, `service.adb.tcp.port` | this module: deleted |
| `/dev/socket/adbd` (stat) | this module, through a susfs `sus_path` rule |
| `@jdwp-control` (connect) | this module, through a susfs `sus_unix` rule |

`ro.adb.secure` is left at `1`, the expected value.

`resetprop -n` writes the property area in memory only. The on-disk store in
`/data/property` is never written, so the spoof lasts until reboot. A watchdog in
`service.sh` re-applies it every 30 seconds, because init rewrites `init.svc.adbd`
whenever adbd changes state and `UsbDeviceManager` rewrites `sys.usb.state` on gadget
events. Only values that drifted are rewritten.

---

## Requirements

- **KernelSU Next** (Magisk-style module layout, `resetprop` from `/data/adb/ksu/bin`).
- **[HMA-OSS](https://github.com/frknkrc44/HMA-OSS)** with `hide_adb` on for the target
  apps, for the settings and USB broadcast side.
- **For socket hiding: the susfs LKM fork**,
  [ymuuuu/susfs4ksu-for-lkm](https://github.com/ymuuuu/susfs4ksu-for-lkm) branch
  `feat/sus-unix-abstract`. It adds the `sus_unix` layer (`/proc/susfs_unix`) and fixes
  the syscall-table hooks on kernels built without `ARM64_BTI_KERNEL`, so the directory
  listing filter works. Without it the module still works, but leaves `init.svc.adbd`
  truthful while adbd runs (see [Gates](#gates)).

---

## Install

1. Download `adb-hide-susfs-vX.Y.Z.zip` from
   [Releases](https://github.com/ymuuuu/adb-hide-susfs/releases).
2. Flash it in the KernelSU Next manager and reboot.

For socket hiding, swap KernelSU Next's bundled susfs LKM for the fork before rebooting:

    ksud susfs autoload disable      # stop the bundled susfs LKM
    # flash the fork's susfs_guard_lkm module zip, then:
    touch /data/adb/modules/susfs_guard_lkm/early_load
    # reboot

To go back: uninstall the `susfs_guard_lkm` module and run `ksud susfs autoload enable`.

Check after boot:

    getprop init.svc.adbd            # stopped when hiding works, running otherwise
    getprop persist.sys.usb.config   # mtp
    cat /proc/susfs_unix             # hook=1 and @jdwp-control listed

---

## Configuration

Edit `/data/adb/modules/adb-hide-susfs/config.sh`, then reboot.

| Key | Default | What |
|---|---|---|
| `HIDE_ADBD_SOCKETS` | `1` | Add the `sus_path` and `sus_unix` rules when the fork LKM is loaded. |
| `REAL_DISABLE_ADB` | `0` | Turn ADB off for real at boot (BRENE behaviour). Kills your adb session. |
| `VSOCK_ONLY_ON_EMULATOR` | `1` | On an emulator, make adbd listen on vsock only. |
| `LISTEN_PORTS_DEC` | `5555` | TCP ports, in decimal, that count as a live ADB endpoint. |
| `WATCH_INTERVAL_S` | `30` | Watchdog interval. |
| `LOG_ON` | `0` | Log every write to `/data/adb/adb-hide-susfs/logs.txt`. |
| `SPOOF_*`, `VAL_*`, `DEL_PROPS` | | Per-property switches and values. |

---

## Gates

Spoofing `init.svc.adbd=stopped` while an app can prove adbd runs turns Duck's WARNING
into a DANGER contradiction. So before every pass the module checks what an app can see,
and only spoofs when nothing contradicts it.

**Listener gate.** A TCP socket in LISTEN state on `LISTEN_PORTS_DEC` answers the ADB
handshake (`INIT_STOPPED_WITH_ADB_PROTOCOL`). Nothing hides that, so a listener always
keeps `init.svc.adbd` truthful.

**Liveness gate.** On a USB phone there is no TCP listener, but two other surfaces
exist while adbd runs:

- `INIT_STOPPED_WITH_ADB_INIT_SOCKET`: `stat("/dev/socket/adbd")` from an app gets
  `EACCES`, which proves the file exists. init removes it only when adbd stops.
- `INIT_STOPPED_WITH_ADB_JDWP_SOCKET`: `connect()` to the abstract socket
  `@jdwp-control`, which adbd binds, succeeds.

adbd counts as alive if `pidof adbd` finds it, `/dev/socket/adbd` exists,
`@jdwp-control` is in `/proc/net/unix`, or a TCP listener is up. While it is alive and
the sockets are visible, `init.svc.adbd` stays `running`.

**Socket hiding.** With the fork LKM loaded, each pass adds a `sus_path` rule for
`/dev/socket/adbd` and a `sus_unix` rule for `jdwp-control`. A hidden app's `stat()`
then gets `ENOENT`, the socket is dropped from directory listings, and `connect()` to
`@jdwp-control` gets `ECONNREFUSED`, the same answer as for a name nobody bound. The
module checks that the `connect` hook is armed and the listing filter is loaded, and only
then lets the `init.svc.adbd` spoof apply while adbd runs. init creates a new socket
inode every time adbd starts, so the `sus_path` rule is replaced when the inode changes.

**USB config timing.** `sys.usb.config` and `persist.sys.usb.config` are spoofed only
after `sys.boot_completed=1`. Spoofing them earlier made `AdbService` read USB adb as off
and write the real `adb_enabled=0`, so USB debugging really turned off.

**Emulator, vsock only.** An x86_64 AVD's adbd finds no USB gadget and also listens on
TCP 5555, which an app can probe. With `VSOCK_ONLY_ON_EMULATOR=1` the module sets
`service.adb.listen_addrs=vsock:5555` at post-fs-data, before adbd starts, and deletes
the property 10 seconds after boot completes. It applies only when `/proc/bootconfig`
has `androidboot.qemu = "1"` and `/dev/vsock` exists. `adb connect` over TCP to the
emulator stops working; use `emulator-5554`.

---

## Limits

- After adbd restarts, the new `/dev/socket/adbd` is visible to apps until the next
  watchdog tick (up to `WATCH_INTERVAL_S`) replaces the rule.
- A TCP ADB listener (`adb tcpip`, wireless debugging) cannot be hidden. The gate then
  keeps `init.svc.adbd` truthful, so Duck reports a WARNING, not a contradiction.
- Without the fork LKM, Duck still reports ADB as active while adbd runs. Only turning
  ADB off for real (USB debugging off, or `REAL_DISABLE_ADB=1`) gives a clean card.
- Do not run it next to a NoEmulator build that sets `service.adb.listen_addrs` on the
  same AVD: both set the same property.

---

## Uninstall

Removing the module stops the watchdog, restores the values saved at boot in
`/data/adb/adb-hide-susfs/saved.txt` (persistent ones with `-p`, so the store matches
again), removes both socket rules and deletes the vsock listen property if still set.

---

## Files

```text
adb-hide-susfs/
├── module/
│   ├── module.prop      # module id and version
│   ├── config.sh        # switches, spoof values, watchdog interval
│   ├── utils.sh         # gates, socket rules, property helpers
│   ├── post-fs-data.sh  # early pass, saves originals
│   ├── service.sh       # late pass and watchdog loop
│   └── uninstall.sh     # restore and clean up
├── build.sh             # zips module/ into a flashable zip
├── FIX-adb-offline-after-reboot.md   # write-up of the v1.1.2 USB config timing fix
└── LICENSE              # AGPL-3.0
```

---

## Credits

- [BRENE](https://github.com/rrr333nnn333/BRENE) by rrr333nnn333, where the property
  logic comes from.
- [susfs4ksu-for-lkm](https://github.com/inforcqb/susfs4ksu-for-lkm) by inforcqb, the
  susfs LKM the socket hiding builds on.
- [HMA-OSS](https://github.com/frknkrc44/HMA-OSS) by frknkrc44, for the settings and
  broadcast side.

## License

AGPL-3.0, the license of BRENE, which this module's code is ported from.
