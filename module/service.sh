#!/system/bin/sh
# adb-hide-susfs: late pass plus drift watchdog
# init rewrites init.svc.adbd on every daemon state change and
# UsbDeviceManager rewrites sys.usb.state on gadget events, so props
# are re asserted on a timer and only rewritten when the value drifted
MODDIR=${0%/*}
# shellcheck disable=SC2154
. "${MODDIR}/config.sh"
. "${MODDIR}/utils.sh"

save_originals
assert_props

STOPFILE="$PERSISTENT_DIR/stop"

if [ -e "$STOPFILE" ]; then
	# leftover stop marker from a previous uninstall attempt
	rm -f "$STOPFILE"
fi

if [ "$REAL_DISABLE_ADB" = 1 ]; then
	# BRENE boot-completed behavior, flips the real setting so adbd
	# stops for real. Keep 0 on any device you reach over adb.
	settings put global adb_enabled 0
	settings put global adb_wifi_enabled 0
	[ "$LOG_ON" = 1 ] && echo "adbhide: real disable applied" >> "$PERSISTENT_DIR/logs.txt"
fi

(
	# the USB config props wait for boot completed, AdbService.systemReady
	# reads persist.sys.usb.config during boot and writes the real
	# Settings.Global adb_enabled from it
	while [ "$(getprop sys.boot_completed)" != 1 ]; do
		[ -e "$STOPFILE" ] && exit 0
		sleep 2
	done
	save_originals
	assert_props
	assert_usb_config_props
	[ "$LOG_ON" = 1 ] && echo "adbhide: boot completed, usb config pass done" >> "$PERSISTENT_DIR/logs.txt"
	if [ -n "$(prop_get "$VSOCK_LISTEN_PROP")" ]; then
		sleep "$VSOCK_PROP_GRACE_S"
		delete_prop_if_exists "$VSOCK_LISTEN_PROP"
	fi
	while [ ! -e "$STOPFILE" ]; do
		sleep "$WATCH_INTERVAL_S"
		assert_props
		assert_usb_config_props
	done
) &
echo $! > "$PERSISTENT_DIR/watchdog.pid"

[ "$LOG_ON" = 1 ] && echo "adbhide: service watchdog pid $(cat "$PERSISTENT_DIR/watchdog.pid") interval ${WATCH_INTERVAL_S}s" >> "$PERSISTENT_DIR/logs.txt"
exit 0
