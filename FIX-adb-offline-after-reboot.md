# Fix: adb comes back `offline` after a reboot

Status: fixed in v1.1.2 (2026-10-20), pending device verification. Written 2026-10-18 from a NoEmulator session.

v1.1.2 implements the proposed fix below: `assert_usb_config_props` in `utils.sh` writes
`sys.usb.config` and `persist.sys.usb.config` only after `sys.boot_completed=1` (from the
`service.sh` watchdog subshell). `sys.usb.state` is still spoofed at post-fs-data. Also fixed:
the listener gate port is now zero padded (`printf '%04X'`).

## What happened

On the Pixel9P-A16-GP AVD, with v1.1.1 installed, a reboot at 21:23 came back with
`adb devices` showing `emulator-5556 offline`. The home screen was up. Restarting the adb
server did not help. Toggling Settings > Developer options > USB debugging off and on
brought adb back.

A second reboot at 21:47 kept adb, with the same root cause present (see below).

## Evidence (same boot, read after the toggle)

- Logcat at the toggle: `AdbService: setAdbEnabled(true), mIsAdbUsbEnabled=false`.
  The framework had started this boot with USB adb disabled.
- Logcat at boot (21:23:38): `UsbDeviceManager: Failed to switch USB config to mtp`, then
  `Failsafe 2: Restoring default USB functions.` The gadget config it tried had no `adb`.
- `getprop persist.sys.usb.config` = `mtp`, while `/data/property/persistent_properties`
  holds `persist.sys.usb.config` = `adb`. So the `mtp` is this module's in-memory spoof
  (`resetprop -n`), not a persisted change.
- `/data/adb/adb-hide-susfs/saved.txt` mtime 21:23:15, so an `assert_props` pass ran
  then. Logcat `AdbService: systemReady` was at 21:23:29, after the spoof.

## Cause (partly known)

Known, seen on two boots: the spoof makes Android turn USB adb off for real.

- Boot at 21:47 (NoEmulator reinstalled, adb stayed `device`): logcat
  `AdbService: systemReady` at 21:47:19.969, then
  `setAdbEnabled(false), mIsAdbUsbEnabled=false` at 21:47:20.000.
  Afterwards `settings get global adb_enabled` = `0` while `getprop persist.sys.usb.config` = `mtp`.
- `AdbService.systemReady` derives "USB adb on" from `persist.sys.usb.config` containing
  `adb`, and writes `Settings.Global.adb_enabled` from it. Unverified: from memory of AOSP
  `AdbService.java`; open it to confirm. The log lines above match it.

So this is not a spoof any more: the module flips the real `adb_enabled` setting to 0 on
every boot. Developer options shows USB debugging off. HMA's `hide_adb` spoof of the same
setting becomes moot.

Not known: why the 21:23 boot went `offline`. The 21:47 boot had the same
`mIsAdbUsbEnabled=false` and adb kept working, because the emulator's adbd runs over the
qemu pipe and kept running (`init.svc.adbd=running`, pid present). So the setting flip
alone does not explain `offline`. Candidates, none checked: adbd needed the framework's
key-auth socket (`AdbDebuggingManager` is not started while adb is disabled; logcat at the
toggle shows `Connection refused` on that socket), or the failed gadget switch
(`Failed to switch USB config to mtp`) restarted adbd mid-handshake. Settle it by
rebooting with `LOG_ON=1` and capturing `logcat -b all | grep -iE 'adbd|AdbDebugging|usb'`
on a boot that goes offline (read it from the emulator console or after the toggle).

## Proposed fix

Do not spoof the two USB config props until boot has completed. Apps only read them after
boot, so hiding is unaffected.

1. `post-fs-data.sh`: run a pass that skips `sys.usb.config` and `persist.sys.usb.config`.
   `init.svc.adbd`, `sys.usb.state` and the deletes can stay early.
2. `service.sh`: before the first full pass, wait for boot:
   ```sh
   until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
   ```
   then `assert_props` as today, and the watchdog loop.
3. One way to express it in `utils.sh`: give `assert_props` a mode argument, or split the
   USB config writes into `assert_usb_config_props` and call it only after boot completed.
   Avoid a boolean flag argument; two functions read better.

Also worth checking while there: whether spoofing `sys.usb.state` early has a similar
effect on `UsbDeviceManager`. Not observed, not ruled out.

## Verify

- Reboot 5 times; `adb devices` shows `device` each time with no toggle.
- After boot, `getprop persist.sys.usb.config` reads `mtp` (spoof still applied).
- Logcat: no `mIsAdbUsbEnabled=false`, no `Failed to switch USB config`.
- `settings get global adb_enabled` reads `1` after boot (HMA still spoofs it to apps).
