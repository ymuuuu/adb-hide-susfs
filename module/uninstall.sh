#!/system/bin/sh
# adb-hide-susfs: stop watchdog and restore original prop values
MODDIR=${0%/*}
. "${MODDIR}/config.sh"
. "${MODDIR}/utils.sh"

touch "$PERSISTENT_DIR/stop"
if [ -f "$PERSISTENT_DIR/watchdog.pid" ]; then
	WDPID=$(cat "$PERSISTENT_DIR/watchdog.pid")
	kill "$WDPID" 2>/dev/null
	rm -f "$PERSISTENT_DIR/watchdog.pid"
fi

restore_originals
remove_socket_hiding
delete_prop_if_exists "$VSOCK_LISTEN_PROP"
rm -f "$PERSISTENT_DIR/saved.txt"
exit 0
