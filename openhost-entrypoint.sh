#!/bin/bash
#
# openhost-entrypoint.sh
#
# Bridge between the OpenHost app contract and the QEMU+TempleOS
# runtime.  Three jobs:
#
#   1. Make sure the persistent disk image exists at
#      $OPENHOST_APP_DATA_DIR/templeos.qcow2.  Create it the first
#      time we run.
#   2. Start QEMU with the install ISO always attached as a
#      CD-ROM and boot order=cd (disk first, CD-ROM as fallback).
#      A fresh disk has no MBR so QEMU falls through to the ISO
#      and the user lands on the installer; once installed, the
#      disk MBR satisfies the disk-first boot order and the ISO
#      stays attached but is never used as the boot medium again.
#   3. Start websockify in noVNC mode so browsers can reach QEMU's
#      VNC server.
#
# Failure policy: fail loud.  A half-running emulator with no
# browser path or no disk would produce a confusing "blank screen"
# experience.  We'd rather have the container die and OpenHost
# surface an error.

set -euo pipefail

log() { printf '[openhost-entrypoint] %s\n' "$*"; }
die() {
    log "FATAL: $*" >&2
    exit 1
}

if [[ -z "${OPENHOST_APP_DATA_DIR:-}" ]]; then
    die "OPENHOST_APP_DATA_DIR is not set; refusing to start."
fi

PERSIST_DIR="$OPENHOST_APP_DATA_DIR"
DISK="$PERSIST_DIR/templeos.qcow2"
ISO=/opt/TempleOS.ISO

# ---------------------------------------------------------------- disk
#
# A fresh qcow2 backed by a 1 GiB virtual disk is ~200 KB on disk.
# TempleOS' Red Sea filesystem (its native FS) doesn't need much:
# the full distro is 17 MB, the IDE ships with maybe another 50 MB
# of source, and user files are tiny (TempleOS is a single-user OS
# with no concept of accounts).  1 GiB is plenty of slack.

if [[ ! -f "$DISK" ]]; then
    log "Creating fresh 1 GiB qcow2 disk at $DISK"
    if ! qemu-img create -f qcow2 "$DISK" 1G; then
        die "qemu-img create failed; check that $PERSIST_DIR is writable."
    fi
fi

# ---------------------------------------------------------------- boot mode
#
# We always attach the install ISO as a CD-ROM and use boot
# order=cd (disk first, then CD-ROM).  On first boot the qcow2
# has no MBR, so QEMU falls through to the CD-ROM and the user
# lands on the TempleOS installer.  After the installer writes a
# Red Sea filesystem to the disk, the disk's MBR satisfies QEMU's
# disk-first boot order and the CD-ROM is never used again.
#
# This matches how a physical PC behaves with the install media
# left in the tray, and avoids needing any explicit "installation
# done" signal — the disk MBR is the source of truth.

QEMU_ARGS=(
    -name "templeos,process=qemu-templeos"
    # TempleOS V5 prints "Requires 512Meg of RAM Memory" at boot if
    # given less; the warning is non-fatal but ugly, and lazy
    # allocation means the host barely notices the difference.
    -m 512
    # TCG (no KVM): we don't get /dev/kvm in the OpenHost sandbox
    # and TempleOS is so simple that the JIT translation overhead
    # is invisible.
    -accel tcg
    # TempleOS uses 640x480 16-color VGA.  -vga std exposes a
    # standard QEMU/Cirrus-style VGA card the OS knows how to drive.
    -vga std
    # No audio: QEMU's default machine type for x86_64 (q35, pc)
    # doesn't include a sound card unless we add one, so we just
    # don't specify -audiodev / -soundhw at all.  TempleOS'
    # PC-speaker beeps go to stdout/dev-null; nothing crucial.
    # No network.  TempleOS has no TCP/IP stack; a NIC would
    # just be ignored.
    -netdev user,id=none0,restrict=on
    # The persistent disk.  -drive (not -hda) so we can specify
    # cache mode.  cache=writeback is safe enough for a single-user
    # OS that doesn't fsync; if QEMU is killed mid-write the worst
    # case is a partially-written file inside TempleOS, which the
    # user will notice immediately.
    -drive "file=$DISK,format=qcow2,if=ide,index=0,cache=writeback"
    # VNC on loopback.  websockify proxies the WebSocket->TCP
    # bridge from the public port (6080) to here.  ":0" = port
    # 5900.  share=allow-exclusive lets a second client take over
    # (e.g. if the first browser tab is closed without
    # disconnecting cleanly).
    -vnc "127.0.0.1:0,share=allow-exclusive"
    # The default machine type would also try to open an SDL/GTK
    # display; -display none turns that off without disturbing the
    # -vnc server.
    -display none
    # No QEMU monitor on stdin: we want stdin for the foreground
    # logger.  -monitor none disables the default redirect.
    -monitor none
    # Dies when TempleOS triple-faults instead of rebooting in
    # place; we'd rather have the supervisor see exit-code != 0
    # and decide whether to restart.
    -no-reboot
)

log "Attaching install ISO; QEMU boot order is disk first, then CD-ROM"
log "(On first boot the disk has no MBR so QEMU falls through to the"
log " CD-ROM and you land on the TempleOS installer.  After you've"
log " installed to disk, the disk's MBR takes precedence on every"
log " subsequent boot and the ISO is silently ignored.)"
QEMU_ARGS+=(
    -cdrom "$ISO"
    -boot "order=cd,menu=off"
)

# ---------------------------------------------------------------- websockify
#
# Listens on $LISTEN_PORT (the manifest's port, 6080), serves the
# noVNC client from /usr/share/novnc, and reverse-proxies WebSocket
# upgrade requests on /websockify to QEMU's VNC port.
#
# We keep this in a child shell so we can wait on QEMU separately
# and tear websockify down cleanly when QEMU exits.

LISTEN_PORT="${PORT:-6080}"

# /usr/share/novnc/index.html is our placeholder.  noVNC's lite
# client lives at vnc_lite.html in the same dir; our index.html
# redirects / -> vnc_lite.html with the right query string so the
# user just hits the app URL and the connection autostarts.

start_websockify() {
    log "Starting websockify on 0.0.0.0:$LISTEN_PORT"
    websockify \
        --web /usr/share/novnc \
        "0.0.0.0:$LISTEN_PORT" \
        "127.0.0.1:5900" &
    WEBSOCKIFY_PID=$!
    log "websockify pid=$WEBSOCKIFY_PID"
}

stop_websockify() {
    if [[ -n "${WEBSOCKIFY_PID:-}" ]] && kill -0 "$WEBSOCKIFY_PID" 2>/dev/null; then
        log "Stopping websockify (pid $WEBSOCKIFY_PID)"
        kill "$WEBSOCKIFY_PID" 2>/dev/null || true
        wait "$WEBSOCKIFY_PID" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------- supervisor
#
# Restart QEMU if it dies (TempleOS triple-faulting on a buggy
# user program is part of the experience).  Cap the restart rate
# so a perma-crashing image doesn't spin the CPU.
#
# We also watch websockify between QEMU restarts: if it crashed,
# the browser path is dead and QEMU's screen is unreachable, so
# spawn a fresh websockify before starting the next QEMU.

trap 'stop_websockify; exit 130' INT TERM

start_websockify

# Give websockify a moment to bind before QEMU starts; if the order
# is reversed, the noVNC HTML gets served before VNC is reachable
# and the user sees a "Failed to connect" toast.
sleep 1

ensure_websockify() {
    if [[ -z "${WEBSOCKIFY_PID:-}" ]] || ! kill -0 "$WEBSOCKIFY_PID" 2>/dev/null; then
        log "websockify is not running; starting it"
        start_websockify
        # Same race as the initial start: give it a moment to bind.
        sleep 1
    fi
}

restart_count=0
while true; do
    ensure_websockify
    log "Starting QEMU (restart_count=$restart_count)"
    if qemu-system-x86_64 "${QEMU_ARGS[@]}"; then
        log "QEMU exited cleanly; container is shutting down"
        break
    fi
    rc=$?
    log "QEMU exited with code $rc; restarting in 2s"
    restart_count=$((restart_count + 1))
    if (( restart_count > 10 )); then
        die "QEMU has crashed $restart_count times; bailing.  Check the persistent disk image at $DISK for corruption."
    fi
    sleep 2
done

stop_websockify
log "Container exit"
