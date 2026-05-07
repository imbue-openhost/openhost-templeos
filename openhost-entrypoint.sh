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
#   2. Start QEMU with the right -boot/-cdrom/-drive args.  Until
#      the user has installed TempleOS to disk we keep the install
#      ISO attached and boot from it; afterwards we switch to
#      booting the disk only.
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
INSTALLED_MARKER="$PERSIST_DIR/.installed"
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
# First boot: persistent dir has the qcow2 we just created but no
# .installed marker.  We attach the install ISO and tell QEMU to
# boot from CD-ROM first, falling back to disk.  The user runs
# the TempleOS installer (a one-time, ~30-second operation) and
# then writes the marker.
#
# Subsequent boots: the marker exists, so we boot directly from
# disk and skip the ISO entirely.  Faster and avoids the user
# accidentally re-installing on top of their work.
#
# We can't really automate the install: TempleOS' installer asks
# a few questions (keyboard layout, locale, CPU count) that we'd
# have to drive over a screen we don't see.  The interactive
# install is fast enough that scripting it isn't worth the
# brittleness.
#
# We expose a tiny HTTP endpoint so the user can mark the install
# complete from inside their host browser, but for v0.1 we just
# accept that the user touches the marker file themselves once
# done (`oh app exec templeos touch /data/app_data/templeos/.installed`,
# or via the file-browser app on the same compute space).

QEMU_ARGS=(
    -name "templeos,process=qemu-templeos"
    # 64 MiB is comfortable for TempleOS (its kernel needs ~16 MiB,
    # the rest is user programs + RAMdisk).  Bumping this gains
    # nothing for vanilla TempleOS but stays cheap.
    -m 64
    # TCG (no KVM): we don't get /dev/kvm in the OpenHost sandbox
    # and TempleOS is so simple that the JIT translation overhead
    # is invisible.
    -accel tcg
    # TempleOS uses 640x480 16-color VGA.  -vga std exposes a
    # standard QEMU/Cirrus-style VGA card the OS knows how to drive.
    -vga std
    # No sound.  TempleOS' audio is a beep generator; nothing
    # important is lost by dropping it, and routing PCM through
    # noVNC's audio channel adds complexity we don't need.
    -audio none
    # No network.  TempleOS has no TCP/IP stack; a NIC would
    # just be ignored.
    -netdev user,id=none0,restrict=on
    # The persistent disk.  -drive (not -hda) so we can specify
    # cache mode.  cache=writeback is safe enough for a single-user
    # OS that doesn't fsync; if QEMU is killed mid-write the worst
    # case is a partially-written file inside TempleOS, which the
    # user will notice immediately.
    -drive "file=$DISK,format=qcow2,if=ide,index=0,cache=writeback"
    # Display via VNC on loopback.  websockify proxies the
    # WebSocket->TCP bridge from the public port (6080) to here.
    # ":0" = port 5900.  share=allow-exclusive lets a second
    # client take over (e.g. if the first browser tab is closed
    # without disconnecting cleanly).
    -display "vnc=127.0.0.1:0,share=allow-exclusive"
    # No QEMU monitor on stdin: we want stdin for the foreground
    # logger.  -monitor none disables the default redirect.
    -monitor none
    # Dies when TempleOS triple-faults instead of rebooting in
    # place; we'd rather have the supervisor see exit-code != 0
    # and decide whether to restart.
    -no-reboot
)

if [[ ! -f "$INSTALLED_MARKER" ]]; then
    log "First boot: attaching install ISO and booting from CD-ROM"
    log "(Once TempleOS finishes installing to disk, run:"
    log "  oh app exec templeos touch $INSTALLED_MARKER"
    log " to switch to disk-only boot on subsequent restarts.)"
    QEMU_ARGS+=(
        -cdrom "$ISO"
        -boot "order=dc,menu=off"
    )
else
    log "Booting from persistent disk (installed marker present)"
    QEMU_ARGS+=(
        -boot "order=c,menu=off"
    )
fi

# ---------------------------------------------------------------- websockify
#
# Listens on $LISTEN_PORT (the manifest's port, 6080), serves the
# noVNC client from /usr/share/novnc, and reverse-proxies WebSocket
# upgrade requests on /websockify to QEMU's VNC port.
#
# We keep this in a child shell so we can wait on QEMU separately
# and tear websockify down cleanly when QEMU exits.

LISTEN_PORT="${PORT:-6080}"

# /usr/share/novnc/index.html is our placeholder; vnc.html is
# noVNC's actual client.  We redirect / -> vnc.html through a
# small index that auto-loads the client with the right path.

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

trap 'stop_websockify; exit 130' INT TERM

start_websockify

# Give websockify a moment to bind before QEMU starts; if the order
# is reversed, the noVNC HTML gets served before VNC is reachable
# and the user sees a "Failed to connect" toast.
sleep 1

restart_count=0
while true; do
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
