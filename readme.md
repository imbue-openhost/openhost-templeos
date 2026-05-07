# openhost-templeos

[Terry A. Davis's TempleOS](https://templeos.org), running inside QEMU,
viewable from any modern web browser, packaged as an OpenHost app.

> **TempleOS is a 64-bit, ring-0, single-address-space, single-user,
> public-domain operating system.  It expects to own the whole machine,
> so we run it in an emulator and pipe its VGA framebuffer out over
> noVNC.**  TempleOS itself is in the public domain per Terry's wishes.

## What you get

- A persistent TempleOS install you can reach at
  `https://templeos.<your-compute-space>/`.
- The full TempleOS desktop (HolyC compiler, demos, games, the works)
  in a 640x480x16-color VGA window scaled to fit your browser.
- A 1 GiB qcow2 disk image stored on the OpenHost persistent volume
  that survives container rebuilds.

## Architecture

```
   browser  --HTTPS-->  OpenHost router  --HTTP-->  websockify (:6080)
                                                     |
                                                     | (WebSocket->TCP)
                                                     v
                                              QEMU VNC (:5900)
                                                     |
                                                     v
                                                  TempleOS
```

The whole thing is one container.  QEMU runs in user space (no KVM,
no `/dev/kvm`); TempleOS doesn't care about the slowdown — its kernel
has no idle loop and the JIT translation cost is invisible at the OS's
working scale.

## Deploying

```sh
oh app deploy https://github.com/imbue-openhost/openhost-templeos --wait
```

The app is gated behind the OpenHost owner-auth wall (no
`public_paths` is declared).  Only you can reach the URL.

## First boot

The image ships with the TempleOS install ISO at `/opt/TempleOS.ISO`,
attached to QEMU as a CD-ROM device on every boot.  QEMU's boot order
is `cd` — disk first, CD-ROM as fallback.  On first boot the disk has
no MBR, so QEMU falls through to the CD-ROM and you land on the
TempleOS installer.  Walk through it once (~30 seconds, mostly hitting
Enter; pick "Yes" to install, US keyboard layout `1`, CPU count `1`).

After the installer writes a Red Sea filesystem to the disk, the disk
has a valid MBR and QEMU's boot order picks it up first on every
subsequent boot.  The CD-ROM stays attached but is never the boot
medium again — same as how a physical PC behaves with the install
media left in the tray.

There's no "mark complete" step needed.  The disk MBR is the source
of truth.

## Running TempleOS

The basics:

- **Welcome page** appears on first login.  Hit any key to dismiss.
- **HolyC REPL** is the default shell.  Type `Cd("..");` to go up,
  `Dir;` to list, `Edit("foo.HC");` to open a file.
- **`Adam("...");`** evaluates HolyC and is roughly TempleOS' eval()
  for arbitrary code.
- **Demos** live under `~/Demo/`.  Load with `Cd("~/Demo"); Demo;`.
- **Games** are under `~/Adam/Games/`.

If you find yourself stuck, a [TempleOS cheat sheet](https://harrisontotty.github.io/p/a-lang-tour-of-temple-os)
covers the basics.

The mouse works, the keyboard works.  TempleOS uses ASCII-art for
most everything so plain noVNC is fine; the 60Hz framebuffer
streaming over WebSocket isn't fast enough for the FlightSim demo
to be playable, but everything else is responsive.

## Persistence and backups

The single source of truth is `$OPENHOST_APP_DATA_DIR/templeos.qcow2`
on the host (typically `/data/app_data/templeos/templeos.qcow2`).
Back it up, or copy it elsewhere, the same way you would any other
OpenHost app's persistent data.

A fresh qcow2 with TempleOS installed and untouched is ~30 MB; it
grows as you write to TempleOS.

To reset to factory defaults: stop the app, delete the `.installed`
marker AND `templeos.qcow2`, restart the app, run through the
installer again.

## Resource use

Defaults: 512 MiB RAM, 0.5 CPU.  TempleOS uses ~64 MiB RAM at runtime;
the rest is QEMU overhead and slack.  Bump these in `openhost.toml`
if you load a CPU-heavy demo, but the emulator's TCG JIT is the
bottleneck before any RAM-related limit kicks in.

## Security

- The desktop is **owner-only** (no `public_paths`).  Anyone who
  reaches the URL can drive the emulated machine; OpenHost auth
  ensures only you do.
- TempleOS has no concept of security boundaries; it runs everything
  in ring 0 in a single address space.  This is fine because the
  whole machine is QEMU, and QEMU has its own well-tested userspace
  isolation.  An attacker who compromises TempleOS is inside QEMU,
  not inside the OpenHost container.
- No special Linux capabilities, no privileged opt-in, no devices.
  This is one of the cleanest OpenHost apps: a normal-uid container
  running an unprivileged user-space emulator.

## Known limitations

- **No KVM.**  The TCG JIT is fast enough that you won't notice on
  TempleOS' workload, but if you ever wanted GPU passthrough or
  hardware-accelerated emulation you'd need a different platform.
- **No audio.**  TempleOS' audio (PC speaker beeps and the
  occasional chiptune game soundtrack) is dropped.  Adding it would
  mean routing PCM through noVNC's optional audio channel.
- **No network.**  TempleOS has no TCP/IP stack at all.  Even if
  QEMU exposed a NIC, TempleOS wouldn't know how to talk to it.
- **Mouse capture quirks.**  Some demos that use absolute mouse
  positioning (FlightSim) interact oddly with noVNC's mouse capture.
  Tap Ctrl+Alt+G in noVNC to release pointer capture if you get
  stuck.

## Files

- `openhost.toml` — OpenHost manifest.
- `Dockerfile` — debian-slim + qemu + novnc + the TempleOS ISO.
- `openhost-entrypoint.sh` — creates the qcow2 disk on first boot,
  starts QEMU and websockify, restarts QEMU if it crashes.
- `index.html` — small landing page that redirects to noVNC's
  auto-connecting lite client with the right WebSocket path.
