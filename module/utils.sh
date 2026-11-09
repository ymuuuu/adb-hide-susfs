#!/system/bin/sh
# Helpers ported from BRENE utils.sh spoof_system_properties, ADB subset
# shellcheck disable=SC2034
PATH=/data/adb/ksu/bin:$PATH
MODDIR=${0%/*}

prop_get() {
	resetprop "$1" 2>/dev/null
}

# BRENE if_prop_exits_resetprop_n, writes only when the prop exists and
# differs, never touches the on disk persistent store (no -p flag)
set_prop_no_p() {
	local NAME=$1
	local VALUE=$2
	local CUR
	CUR=$(prop_get "$NAME")
	[ -z "$CUR" ] && return
	[ "$CUR" = "$VALUE" ] && return
	resetprop -n "$NAME" "$VALUE"
	log_set "$1" "$VALUE"
}

delete_prop_if_exists() {
	local NAME=$1
	[ -z "$(prop_get "$NAME")" ] && return
	resetprop -d "$NAME"
	log_set "$1" deleted
}

# restore the saved original value of one prop, no-op when equal
restore_prop_from_saved() {
	local NAME=$1
	local SAVED
	SAVED=$(grep "^${NAME}|" "$PERSISTENT_DIR/saved.txt" 2>/dev/null | head -n 1 | cut -d'|' -f2)
	if [ "$SAVED" = "" ]; then
		delete_prop_if_exists "$NAME"
		return
	fi
	[ "$(prop_get "$NAME")" = "$SAVED" ] && return
	resetprop -n "$NAME" "$SAVED"
	log_set "$1" "restored to saved value $SAVED"
}

# Duck protocol confirmation gate. Spoofing init.svc.adbd while a real
# TCP ADB listener answers the ADB wire handshake produces the HIGH
# INIT_STOPPED_WITH_ADB_PROTOCOL contradiction (Duck AdbRuntimeFindings
# stableProtocolEndpoint). A LISTEN state entry (0A in st column) on
# any configured port means a live endpoint exists, so the adbd process
# prop spoofs skip and stale spoofs get undone. Ports come in as
# decimal from config.sh and are converted here, ipv4 and ipv6 tables
# are both parsed, port is the last colon field of local_address and
# compared case insensitive since the kernel prints uppercase hex.
# /proc/net/tcp always prints the port as 4 hex digits, so the printf
# is zero padded to 4 or ports below 4096 never match.
adb_listener_present() {
	local PORT_DEC PORT_HEX FILE
	for PORT_DEC in $LISTEN_PORTS_DEC; do
		PORT_HEX=$(printf '%04X' "$PORT_DEC")
		for FILE in /proc/net/tcp /proc/net/tcp6; do
			[ -r "$FILE" ] || continue
			awk -v p="$PORT_HEX" '
NR>1 {
	n = split($2, a, ":")
	if (toupper(a[n]) == toupper(p) && $4 == "0A") { found = 1; exit }
}
END { exit !found }
' "$FILE" && return 0
		done
	done
	return 1
}

# Duck liveness gate. Apart from the TCP protocol probe above, Duck
# compares init.svc.adbd=stopped with two adbd surfaces an app can see
# (AdbRuntimeFindings, INIT_STOPPED_WITH_ADB_INIT_SOCKET and
# INIT_STOPPED_WITH_ADB_JDWP_SOCKET):
# - /dev/socket/adbd: init creates it when adbd starts and unlinks it
#   before it publishes stopped. stat() from an app gets EACCES on the
#   inode, which Duck reads as present.
# - @jdwp-control: adbd binds this abstract socket itself, and an app
#   can connect() to it.
# resetprop cannot hide either one, so while adbd runs the prop must
# read running. A USB-only phone has no TCP listener, so the TCP check
# alone never caught this.
adbd_alive() {
	pidof adbd >/dev/null 2>&1 && return 0
	[ -e /dev/socket/adbd ] && return 0
	grep -q '@jdwp-control$' /proc/net/unix 2>/dev/null && return 0
	adb_listener_present
}

# Socket hiding through the susfs LKM (ymuuuu/susfs4ksu-for-lkm with the
# sus_unix layer). Both adbd surfaces above become invisible to hidden
# apps, so the liveness gate no longer has to keep init.svc.adbd at
# running:
# - /dev/socket/adbd: a sus_path rule. stat() and directory listings
#   both drop it, but listings only when the kstat layer is armed (it
#   carries the getdents64 filter), so /proc/susfs_kstat must exist.
#   The rule follows the inode, and init makes a new socket every time
#   adbd starts, so the rule is replaced when the inode changed.
# - @jdwp-control: a sus_unix rule, connect() answers ECONNREFUSED.
# Returns 0 only when every surface is hidden right now.
SUS_PATH_NODE=/proc/susfs_path
SUS_UNIX_NODE=/proc/susfs_unix
ADBD_SOCKET=/dev/socket/adbd
JDWP_NAME=jdwp-control

socket_hiding_active() {
	local INO
	[ "$HIDE_ADBD_SOCKETS" = 1 ] || return 1
	[ -w "$SUS_PATH_NODE" ] && [ -w "$SUS_UNIX_NODE" ] || return 1
	[ -e /proc/susfs_kstat ] || return 1
	grep -q "^@${JDWP_NAME}\$" "$SUS_UNIX_NODE" || echo "add $JDWP_NAME" > "$SUS_UNIX_NODE"
	grep -q '^# .* hook=1,' "$SUS_UNIX_NODE" || return 1
	grep -q "^@${JDWP_NAME}\$" "$SUS_UNIX_NODE" || return 1
	if [ -e "$ADBD_SOCKET" ]; then
		INO=$(stat -c %i "$ADBD_SOCKET")
		if ! grep -q "path=${ADBD_SOCKET} .* ino=${INO} " "$SUS_PATH_NODE"; then
			echo "del $ADBD_SOCKET" > "$SUS_PATH_NODE" 2>/dev/null
			echo "add $ADBD_SOCKET" > "$SUS_PATH_NODE" || return 1
			log_set "$ADBD_SOCKET" "sus_path ino $INO"
		fi
	fi
	return 0
}

remove_socket_hiding() {
	[ -w "$SUS_UNIX_NODE" ] && echo "del $JDWP_NAME" > "$SUS_UNIX_NODE" 2>/dev/null
	[ -w "$SUS_PATH_NODE" ] && echo "del $ADBD_SOCKET" > "$SUS_PATH_NODE" 2>/dev/null
	return 0
}

VSOCK_LISTEN_PROP=service.adb.listen_addrs
VSOCK_LISTEN_ADDRS=vsock:5555

# The emulator's boot flag, read from bootconfig rather than from
# ro.boot.qemu, which other modules delete at post-fs-data. vsock is
# how host adb reaches the emulator's adbd, so it must exist.
emulator_with_vsock() {
	grep -q '^androidboot\.qemu = "1"' /proc/bootconfig 2>/dev/null && [ -e /dev/vsock ]
}

vsock_mode_active() {
	[ "$VSOCK_ONLY_ON_EMULATOR" = 1 ] && emulator_with_vsock
}

set_vsock_only_listen() {
	resetprop -n "$VSOCK_LISTEN_PROP" "$VSOCK_LISTEN_ADDRS"
	log_set "$VSOCK_LISTEN_PROP" "$VSOCK_LISTEN_ADDRS"
}

# Seconds the vsock listen prop outlives boot completed. On the AVD init
# stops adbd at boot completed (its sys.usb.config=none action) and
# adbd starts again about 0.4 s later; that start must still read the
# prop. Apps can read the prop's area, so it goes after this.
VSOCK_PROP_GRACE_S=10

log_set() {
	[ "$LOG_ON" = 1 ] && echo "adbhide: $1 -> $2" >> "$PERSISTENT_DIR/logs.txt"
}

# save_originals records the first seen non empty value of each prop.
# Later passes only backfill an entry that is still empty, so values
# written by late boot daemons (init sets init.svc.adbd when adbd
# starts) still land in the snapshot. Values are never overwritten
# once recorded, and spoof passes run after the save pass in the same
# invocation, so a snapshot entry is always pre spoof.
save_originals() {
	mkdir -p "$PERSISTENT_DIR"
	touch "$PERSISTENT_DIR/saved.txt"
	local ALL="init.svc.adbd init.svc_debug_pid.adbd sys.usb.state sys.usb.config persist.sys.usb.config $DEL_PROPS"
	local P V CUR
	for P in $ALL; do
		V=$(prop_get "$P")
		[ -z "$V" ] && continue
		if grep -q "^${P}|" "$PERSISTENT_DIR/saved.txt"; then
			CUR=$(grep "^${P}|" "$PERSISTENT_DIR/saved.txt" | head -n 1 | cut -d'|' -f2)
			[ -n "$CUR" ] && continue
			sed -i "s#^${P}|.*#${P}|$V#" "$PERSISTENT_DIR/saved.txt"
		else
			echo "$P|$V" >> "$PERSISTENT_DIR/saved.txt"
		fi
	done
}

restore_originals() {
	local P V
	[ -f "$PERSISTENT_DIR/saved.txt" ] || return 0
	while IFS='|' read -r P V; do
		[ -z "$P" ] && continue
		if [ -z "$V" ]; then
			delete_prop_if_exists "$P"
		elif [ "${P#persist.}" != "$P" ]; then
			# persistent prop, write the on disk store too so the
			# value survives the next reboot
			resetprop -n -p "$P" "$V"
		else
			resetprop -n "$P" "$V"
		fi
	done < "$PERSISTENT_DIR/saved.txt"
}

# The ADB subset of BRENE spoof_system_properties. The two adbd process
# props are gated on a live listener, sys.usb.state is not (it is not
# feed into any contradiction check by Duck, it only feeds the active OR
# chain). The two USB config props are written by assert_usb_config_props
# after boot completed.
assert_props() {
	local SPOOF_ALLOWED=1 P
	# A TCP listener answers the ADB protocol, which nothing hides, so it
	# always keeps the truth. A local adbd only does so while its sockets
	# are visible to apps.
	if adb_listener_present || { adbd_alive && ! socket_hiding_active; }; then
		SPOOF_ALLOWED=0
		# adbd is live, keep truth and undo any stale spoof written
		# by an earlier pass that ran before adbd started
		if [ "$(prop_get "init.svc.adbd")" = "$VAL_INIT_SVC_ADBD" ]; then
			# adbd runs while the prop reads the spoof value: init
			# would have written running, restore that
			resetprop -n "init.svc.adbd" "running"
			log_set "init.svc.adbd" "running (liveness gate)"
		fi
		restore_prop_from_saved "init.svc_debug_pid.adbd"
	fi
	if [ "$SPOOF_ALLOWED" = 1 ] && [ "$SPOOF_INIT_SVC_ADBD" = 1 ]; then
		set_prop_no_p "init.svc.adbd" "$VAL_INIT_SVC_ADBD"
	fi
	if [ "$SPOOF_ALLOWED" = 1 ] && [ "$SPOOF_INIT_SVC_DEBUG_PID" = 1 ]; then
		set_prop_no_p "init.svc_debug_pid.adbd" "$VAL_INIT_SVC_DEBUG_PID"
	fi
	if [ "$SPOOF_SYS_USB_STATE" = 1 ]; then
		set_prop_no_p "sys.usb.state" "$VAL_SYS_USB_STATE"
	fi
	if [ "$DELETE_ADB_SERVICE_PROPS" = 1 ]; then
		for P in $DEL_PROPS; do
			delete_prop_if_exists "$P"
		done
	fi
}

# The USB config props must only be written after sys.boot_completed=1.
# AdbService.systemReady reads persist.sys.usb.config to derive whether
# USB adb is on, then writes the real Settings.Global adb_enabled from
# it, so an mtp spoof before that point turns USB debugging off for real.
assert_usb_config_props() {
	if [ "$SPOOF_SYS_USB_STATE" = 1 ]; then
		set_prop_no_p "sys.usb.config" "$VAL_SYS_USB_CONFIG"
	fi
	if [ "$SPOOF_PERSIST_USB_CONFIG" = 1 ]; then
		set_prop_no_p "persist.sys.usb.config" "$VAL_PERSIST_USB_CONFIG"
	fi
}
