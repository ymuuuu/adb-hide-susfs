#!/system/bin/sh
# adb-hide-susfs: early prop spoof pass, runs at post-fs-data
MODDIR=${0%/*}
# shellcheck disable=SC2154
. "${MODDIR}/config.sh"
. "${MODDIR}/utils.sh"

if vsock_mode_active; then
	# before adbd starts, which reads it once
	set_vsock_only_listen
fi

save_originals
assert_props

[ "$LOG_ON" = 1 ] && echo "adbhide: post-fs-data pass done" >> "$PERSISTENT_DIR/logs.txt"
exit 0
