# adb-hide-susfs config

# Persistent dir in /data/adb, survives module updates
PERSISTENT_DIR=/data/adb/adb-hide-susfs

# 1 enables, 0 disables
LOG_ON=0

# Watchdog interval in seconds, re asserts props when init or
# UsbDeviceManager rewrites them
WATCH_INTERVAL_S=30

# Prop spoof toggles
SPOOF_INIT_SVC_ADBD=1
SPOOF_INIT_SVC_DEBUG_PID=1
SPOOF_SYS_USB_STATE=1
SPOOF_PERSIST_USB_CONFIG=1
DELETE_ADB_SERVICE_PROPS=1

# Spoof values, safe values per detector expectations
VAL_INIT_SVC_ADBD="stopped"
VAL_INIT_SVC_DEBUG_PID=""
VAL_SYS_USB_STATE="mtp"
VAL_SYS_USB_CONFIG="mtp"
VAL_PERSIST_USB_CONFIG="mtp"

# Props to delete, deleted on boot, restored on uninstall if they
# had a value before
DEL_PROPS="service.adb.root service.adb.tcp.port"

# TCP ADB ports in DECIMAL for the listener gate. The init.svc.adbd
# spoof only applies while no listed port is in LISTEN state, so a live
# adbd endpoint is never contradicted by a spoofed stopped value. Hex
# conversion happens in utils.sh with printf %X, ports here stay
# readable. Default 5555 covers the AVD listener and adb tcpip. Add
# more for custom tcpip ports.
LISTEN_PORTS_DEC="5555"

# Emulator only. 1 starts adbd listening on vsock alone, so the AVD has
# no TCP adb listener for an app to connect to; host adb reaches the
# emulator over vsock. adbd reads service.adb.listen_addrs once, at
# start (packages/modules/adb daemon/main.cpp), so the prop is set at
# post-fs-data and deleted once adbd runs. Applies only when
# /proc/bootconfig says androidboot.qemu = "1" and /dev/vsock exists;
# a real phone's adbd uses USB and is left alone. With no listener the
# gate below lets the init.svc.adbd spoof apply. adb connect over TCP to
# the emulator stops working. If adbd restarts it listens on TCP again
# and the gate restores init.svc.adbd until the next reboot.
VSOCK_ONLY_ON_EMULATOR=1

# BRENE parity option. 1 writes the real settings adb_enabled 0 and
# adb_wifi_enabled 0 at boot, so AdbService stops adbd for real, the
# TCP listener and mDNS advertisement really close, and every ADB
# source reads clean with no gate needed. This kills the adb session
# to the device, do not enable while you control the device over adb.
REAL_DISABLE_ADB=0

# Hide adbd's app-visible sockets through the susfs LKM fork
# (ymuuuu/susfs4ksu-for-lkm, sus_unix layer): a sus_path rule for
# /dev/socket/adbd and a sus_unix rule for @jdwp-control. When both
# are confirmed active the init.svc.adbd spoof applies even while adbd
# runs. Without that LKM (KSUN's bundled build has no /proc/susfs_unix
# and no working getdents filter) nothing is added and init.svc.adbd
# stays truthful as in v1.2.1.
HIDE_ADBD_SOCKETS=1
