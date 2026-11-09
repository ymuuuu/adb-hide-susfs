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

With no listener, the listener gate lets the init.svc.adbd spoof apply,
so on the AVD Duck has nothing to contradict it. No adb mDNS
advertisement was seen on the Android 16 AVD: mdnsd never starts.

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

## Install and verify

Flash adb-hide-susfs-vX.zip in KernelSU Next, reboot, then:

    getprop init.svc.adbd            # expect stopped
    getprop sys.usb.state            # expect mtp
    getprop persist.sys.usb.config   # expect mtp

Expected post run verdicts:

- Duck AdbRuntime: no contradiction ever. On phones with ADB transport
  off all six sources read clean. On emulators the mDNS source keeps a
  plain WARNING while init.svc.adbd matches the live endpoint.
- vdinfos ADB block: adb settings reads keep the HMA spoof, props now
  agree (init.svc.adbd stopped matches adb_enabled spoofed 0 on gated
  devices).
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
