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

# Props start from their real values on every boot, so the snapshot is
# rebuilt here and only describes this boot. Without the reset,
# save_originals keeps the first value ever recorded, from whatever
# boot that was.
rm -f "$PERSISTENT_DIR/saved.txt"
save_originals
assert_props

[ "$LOG_ON" = 1 ] && echo "adbhide: post-fs-data pass done" >> "$PERSISTENT_DIR/logs.txt"
exit 0
