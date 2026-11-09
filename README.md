# adb-hide-susfs

Standalone KernelSU module that ports the ADB hiding subset out of BRENE
(rrr333nnn333/BRENE, module/utils.sh spoof_system_properties). Props only,
no susfs syscall needed. Runs next to ymuu/susfs4ksu-lkm-x64, which keeps
covering path, uname and mount level hiding, this module covers the props
that that layer cannot reach.

## What it hides

Duck Detector AdbRuntime keeps its "ADB enabled" verdict on an OR of six
sources. HMA-OSS already strips the settings and USB broadcast side. This
module strips the prop side:

| Duck source | Value before | Value after module |
|---|---|---|
| Settings.Global adb_enabled | real 1 | spoofed 0 by HMA hide_adb, unchanged here |
| Settings.Global adb_wifi_enabled | real 1 | spoofed 0 by HMA hide_adb |
| USB_STATE sticky broadcast adb extra | present | stripped by HMA BroadcastHook |
| init.svc.adbd | running | stopped (resetprop -n) |
| init.svc_debug_pid.adbd | pid or empty | empty, deleted if present |
| sys.usb.state | adb | mtp |
| sys.usb.config | adb | mtp |
| persist.sys.usb.config | adb | mtp |
| service.adb.root / service.adb.tcp.port | present or missing | deleted |

ro.adb.secure is left at 1, that is the safe value for all checkers.

resetprop -n writes the shared property area without the -p persistent
flag, so the spoof lives until reboot and the on disk store in
/data/property stays untouched by the module. One caveat: system code
that reads the spoofed value may itself set the prop again and property
service persists persist.* writes. Module uninstall therefore restores
persistent props with -p, writing the store back with the value
captured in /data/adb/adb-hide-susfs/saved.txt.

Watchdog: service.sh re asserts every 30 seconds because init rewrites
init.svc.adbd on daemon state change and UsbDeviceManager rewrites
sys.usb.state on gadget events. Only drifted names are rewritten.

## Boot timing (v1.1.2)

sys.usb.config and persist.sys.usb.config are only spoofed after
sys.boot_completed=1. Spoofing them earlier made AdbService derive USB
adb as off from persist.sys.usb.config and write the real
Settings.Global adb_enabled=0, so USB debugging was really turned off
and adb could come back offline. Apps only read these props after boot,
so the hiding is unchanged. Everything else still applies at
post-fs-data: init.svc.adbd, init.svc_debug_pid.adbd, sys.usb.state and
the deletes.

## Listener gate (v1.1)

Spoofing init.svc.adbd to stopped while a real TCP ADB endpoint is in
LISTEN state produces the Duck HIGH finding INIT_STOPPED_WITH_ADB_PROTOCOL
(AdbRuntimeFindings.kt stableProtocolEndpoint): both discovery passes
confirm the ADB AUTH token on the wire while the prop claims the daemon
is stopped. Observed live on the x64 AVD after v1.0.0, report
duck_detector_report_Pixel_8_20261018_122417: verdict flipped from
WARNING "ADB enabled" to DANGER "Runtime contradiction".

The gate removes the contradiction instead of creating it. Every pass
(post-fs-data and each watchdog tick) checks /proc/net/tcp and tcp6 for
a LISTEN socket on LISTEN_PORTS_DEC (default 5555). Ports are decimal
in config.sh and converted to hex with printf inside utils.sh, zero
padded to 4 digits because that is the width /proc/net/tcp prints: the
first v1.1 build hardcoded 15B1 which is actually 5553, the real AVD
listener sits on 15B3 = 5555, so the gate never fired and the spoof
survived a live endpoint. Decimal-in, printf-out prevents that class
of error. Gate behavior:

- listener present: init.svc.adbd and init.svc_debug_pid.adbd are not
  spoofed, and a stale stopped value from an earlier pass is restored
  to the saved original or to running, so the prop always matches the
  live endpoint
- no listener: the spoof applies, this is the all clean path on phones
  with ADB transport off

Why BRENE never showed this on the arm64 device: BRENE also writes the
REAL settings (settings put global adb_enabled 0 in boot-completed.sh),
AdbService stops adbd for real, the listener and mDNS advertisement
really close, so no probe can contradict the spoof. The ports-parity
option is available here as REAL_DISABLE_ADB=1 (same two settings
writes). It kills your adb session, keep it 0 on devices you control
over adb.

## Emulator: adbd on vsock only (v1.2.0)

On an x86_64 AVD adbd finds no USB gadget and listens on TCP 5555 as
well as vsock, so an app can connect to 5555 and get the ADB protocol
back. Host adb (emulator-5554) reaches adbd over vsock, so TCP is not
needed. With VSOCK_ONLY_ON_EMULATOR=1 (default) the module sets
service.adb.listen_addrs=vsock:5555 at post-fs-data, before adbd
starts and reads it, and deletes it after boot, because apps can read
the prop.

It applies only when /proc/bootconfig has androidboot.qemu = "1" and
/dev/vsock exists. bootconfig is read rather than ro.boot.qemu because
other modules delete that prop at post-fs-data. A real phone's adbd
uses USB and is not touched.

With no TCP listener, Duck has no ADB protocol endpoint to probe. Since
v1.2.1 the init.svc.adbd spoof still does not apply while adbd runs
(see the liveness gate below), because /dev/socket/adbd and
@jdwp-control stay visible over vsock too. No adb mDNS advertisement
was seen on the Android 16 AVD: mdnsd never starts.

The prop is kept until 10 s after boot completed, not deleted as soon
as adbd runs. With this module on the AVD, init runs its
sys.usb.config=none action at boot completed, stops adbd, and starts it
again about 0.4 s later (dmesg, four test boots); that second start has
to read the prop too. It still happened with the sys.usb.* spoofs off,
so which write sets it off was not isolated. A boot with NoEmulator
alone showed no such restart.

Costs:
- adb connect over TCP to the emulator stops working. Use emulator-5554.
- If adbd restarts, it reads the deleted prop as empty and listens on
  TCP 5555 again until the next reboot. The gate then restores
  init.svc.adbd, so the verdict falls back to the plain WARNING, never
  the DANGER contradiction.

Set VSOCK_ONLY_ON_EMULATOR=0 to keep the TCP listener; the gate then
keeps init.svc.adbd truthful as in v1.1.

Do not run this module next to a NoEmulator build with #138 (the first
release after v0.8.0) on the same
AVD: NoEmulator sets the same prop and hides init.svc.adbd from apps
only, while this module spoofs it for every process.

## Liveness gate (v1.2.1)

Newer Duck builds have two more HIGH findings that compare
init.svc.adbd=stopped with adbd surfaces an app can see:

- INIT_STOPPED_WITH_ADB_INIT_SOCKET: stat(/dev/socket/adbd) from the app
  gets EACCES on the inode while a made-up sibling path gets ENOENT, so
  the socket exists. init unlinks it before it publishes stopped.
- INIT_STOPPED_WITH_ADB_JDWP_SOCKET: connect() to the abstract socket
  @jdwp-control, which adbd binds itself, succeeds.

resetprop cannot hide either. The v1.1 gate only looked for a TCP
listener, which a phone using adb over USB never has, so the spoof
always applied and Duck reported "2 runtime contradiction(s)" (Pixel 6a,
Android 15, report duck_detector_report_Pixel_6a_20261109_113207).

adbd_alive in utils.sh now treats adbd as live if any of these holds:
pidof adbd, /dev/socket/adbd exists, @jdwp-control is in /proc/net/unix,
or a TCP listener is up. While adbd is live, init.svc.adbd is left at
(or put back to) running. The spoof only applies when adbd is really
stopped.

Duck still reports ADB as active (WARNING) while adbd runs: the real
props, sockets and USB state all say so. Only turning adb off for real
(USB debugging off, or REAL_DISABLE_ADB=1) gets a clean ADB Runtime
card.

The prop snapshot in saved.txt is rebuilt at every post-fs-data, so it
always describes the current boot. It holds the first value seen, at
post-fs-data, which on a Pixel 6a is init.svc.adbd=stopped and
sys.usb.config=mtp, because adbd has not started yet.

## Socket hiding (v1.3.0)

The liveness gate keeps init.svc.adbd truthful because apps can see
adbd's sockets. With the susfs LKM fork
(https://github.com/ymuuuu/susfs4ksu-for-lkm, branch
feat/sus-unix-abstract) those sockets can be hidden instead:

- /dev/socket/adbd: a sus_path rule. That build also fixes the
  syscall-table hooks on kernels without ARM64_BTI_KERNEL, so the
  getdents64 filter drops the name from listings too.
- @jdwp-control: a rule in the new sus_unix layer (/proc/susfs_unix).
  connect() from a hidden app answers ECONNREFUSED, the same as for an
  unbound abstract name.

Each pass (post-fs-data, service and every watchdog tick)
socket_hiding_active adds both rules, replaces the sus_path rule when
adbd restarted (init creates a new socket inode), and returns success
only when /proc/susfs_unix shows the hook armed and /proc/susfs_kstat
exists. Then the init.svc.adbd spoof applies even while adbd runs. A
TCP ADB listener still keeps the truth, since the protocol probe is not
hidden. KSUN's bundled susfs LKM has neither /proc/susfs_unix nor a
working getdents filter on such kernels, so with it nothing changes
from v1.2.1. Set HIDE_ADBD_SOCKETS=0 to turn this off.

Known gap: after adbd restarts, the new socket is visible to apps until
the next watchdog tick (up to WATCH_INTERVAL_S) replaces the rule.

Measured on a Pixel 6a (Android 15) with the LKM loaded live, HMA-OSS
with the BroadcastController fix, and init.svc.adbd=stopped: Duck
Detector's ADB Runtime card reads "ADB state consistent": init socket
absent, JDWP not observed (connection refused), USB no functions, no
contradiction.

Setup on KernelSU Next:

    ksud susfs autoload disable      # stop the bundled susfs LKM
    # flash the fork's susfs_guard_lkm module zip, then:
    touch /data/adb/modules/susfs_guard_lkm/early_load
    # reboot

## Install and verify

Flash adb-hide-susfs-vX.zip in KernelSU Next, reboot, then:

    getprop init.svc.adbd            # running while adbd runs, stopped otherwise
    getprop persist.sys.usb.config   # expect mtp

Expected post run verdicts:

- Duck AdbRuntime: no contradiction. While adbd runs, a WARNING that
  ADB is active. With ADB really off, all sources read clean.
- vdinfos ADB block: adb settings reads keep the HMA spoof, props now
  agree (init.svc.adbd stopped matches adb_enabled spoofed 0) only while
  adbd is really stopped.
- BRENE mode parity: set REAL_DISABLE_ADB=1 to reproduce BRENE's real
  settings toggle. Otherwise real settings are not touched and external
  adb sessions keep working.

## Files

    module/module.prop    module id and description
    module/config.sh      toggles, spoof values, watchdog interval
    module/utils.sh       helpers and prop set, ported from BRENE
    module/post-fs-data.sh early pass
    module/service.sh     late pass plus watchdog loop
    module/uninstall.sh   stops watchdog, restores saved values, deletes
                          the vsock listen prop if still set
    build.sh              zips module into a flashable zip
