# BigMig for MiSTer

A **Big Box Amiga** for the MiSTer board: the Minimig chipset in the FPGA fabric, driven by a
68k that is not in the fabric at all.

BigMig replaces the in-fabric soft CPU with **Emu68-A9**, an ARMv7 just-in-time recompiler
running bare-metal on the second ARM core of the DE10-Nano's HPS. The Amiga custom chips —
Agnus, Denise, Paula, Gary, the CIAs — are the same cycle-accurate Minimig logic they have
always been. Only the processor moved.

The result is an Amiga that is **520 to 770 MIPS**, from 800 MHz to 1.2 GHz of Host Speed, where
Minimig's TG68K is about 12 — selectable as
a **68EC020, a 68040 or a 68060+**, with a **68882-class FPU** and an open SIMD extension — and
whose chip RAM is nonetheless **faster than a real A600's**.

It is fast enough to boot distributions made for the PiStorm and the Vampire — CaffeineOS and
Coffin among them — from their own images, although booting them is not the same as being the
best way to use BigMig (see [PiStorm and Vampire distributions](#pistorm-and-vampire-distributions)).

> **BigMig is a separate core from Minimig, on purpose.** Minimig for MiSTer is excellent and
> mature, and thousands of people have configurations that work. This core diverges in what it
> offers — that is the point of it — and a divergent core has no business overwriting their
> setup. Nothing here touches Minimig: separate `.rbf`, separate config, separate saves. The
> only thing the two share is that BigMig points at the same `/games/Amiga` folder, so your
> disks and hard-drive images are found without copying anything.

---

## The first attempt was Mark Watson's

A hybrid core — the FPGA doing the chipset, an ARM core doing the CPU — had been talked about in
the MiSTer community for years, by Sorgelig among others, and by me. Talking about it is easy.

**Mark Watson built one.** Minimig Hybrid was the first actual attempt, and BigMig exists because
of it: it showed the thing could be made to run at all, and the earliest register blocks of our
seam were his code. That is worth honouring, and we do.

What we did differently is concentrated in one area: **how the two ARM cores are used**, because
that is where responsiveness is won or lost.

* **Core #1 runs bare metal, and only the firmware.** No Linux scheduler on it, no other
  process, no sharing — the JIT owns the core outright. Linux is booted with `maxcpus=1` so it
  never has a claim on it in the first place (that is what the sidecar file below is for).
* **Core #0 runs MiSTer's Main with an explicit priority order**: **USB polling and the OSD
  first**, at the same **1 ms** rate as official Main, then **audio** and the MP3 decoder, then
  the **hard-drive device**, then the file share, with the network bridge last. Input is never
  queued behind anything, and music keeps playing while the disk works: disk work — the part
  that can afford to wait — waits. When the Amiga sits idle the disk and share services back
  off.
* **Emu68 was ported to the Cortex-A9.** Michal Schulz's Emu68 targets AArch64; the A9 on the
  DE10-Nano is 32-bit ARMv7. The JIT's code generator, its cache maintenance and its exception
  paths were rebuilt for that target, which is what makes a bare-metal 68k possible on this
  board at all.

Those three together are what make BigMig both fast *and* comfortable to actually use. "It is
very fast" would only be half a claim; the other half is that it feels like an FPGA core.

---

## What it is

| | |
|---|---|
| **CPU** | **68EC020, 68040 or 68060+**, per config from the OSD, via the Emu68-A9 JIT — **520–770 MIPS** (800 MHz–1.2 GHz), on a dedicated ARM core |
| **FPU** | 68882-class, **double precision** — switchable on the 020, always there on the 040 and 060+ — plus a ROM that puts AmigaOS's maths libraries on it |
| **SIMD** | **OMMX** — an open vector extension; the AMMX instruction set is a subset, so AMMX software runs |
| **Chipset** | OCS / ECS / AGA — unmodified Minimig logic, in the fabric |
| **Chip RAM** | 2 MB, reached through a direct window (see below) |
| **Fast RAM** | 264 MB, served by the JIT from HPS DDR3 |
| **RTG** | **ZZ9000** Zorro III graphics, up to 1920×1080, ARM-native blitter — and a native-rate analog output up to 640×480 |
| **Ethernet** | the **ZZ9000 network function** — the stock `ZZ9000Net.device` takes a DHCP lease and holds a routed IP session on the real LAN |
| **16-bit audio** | **bigmigAHI** — a 16-bit card of our own, with the `bigmigAHI.audio` AHI driver we wrote: 8 streams, 16-bit stereo, mixed on the ARM |
| **MP3** | **MHI** — players that support it (AmigaAMP) hand MP3 decoding to the ARM through `mhibigmig.library` |
| **Hard disk** | **bigmigHD.device** — autoboot, HDF images, raw partition images **and PiStorm/Emu68 SD-card images as they are** |
| **CD** | up to four drives — ISO, CUE and CHD, hot-swappable |
| **Floppy** | ADF, normal and turbo |
| **File sharing** | the **MiSTer Share** (`SHARE:`), on a fast path |
| **Kickstart** | 1.3, 2.0, 3.1, 3.2, 3.2.2, 3.2.3 — including **1 MB ROMs** (512K ext-ROM + 512K Kickstart) |
| **Video / audio / input** | the MiSTer framework, as every other core |

### Not here, and deliberately

* **No slow RAM.** The memory map this core is built around does not have it.
* **No soft CPU.** `fx68k` and `TG68K` are gone from the fabric, not parked — the seam is the
  only chip-bus master. That is what frees the logic and the timing margin.
* **No MiSTer RTG card.** ZZ9000 replaces it.
* **No Gayle IDE.** Storage goes through `bigmigHD.device`.
* **No Toccata.** The MacroSystem Toccata, a Zorro II 16-bit sound card, is not in this core.
  Minimig's implementation of it is good work; here the 16-bit card is bigmigAHI.
* **No MMU translation.** The 68040 and 68060+ answer their full MMU register set and store what
  you write, but translation is never enabled — software that *probes* the MMU is happy,
  software that needs real remapping is out of scope.

---

## Measured

SysInfo 4.4, same install, from 800 MHz to 1.2 GHz of Host Speed:

| presented CPU | MIPS | MFlops | vs A600 |
|---|---|---|---|
| 68EC020 + 68882 | **520 – 770** | 20.5 – ~30 | ~940 – 1400× |
| 68040 | 518 – ~770 | 19.4 – ~29 | ~930 – 1400× |

The 800 MHz figures are SysInfo's own readings; at 1.2 GHz SysInfo reads 760–770 MIPS, and the
rest follows the clock.

* **43× to 64×** Minimig's TG68K with Data Cache.
* As a 68040 the OS confirms it end to end: SysInfo reads *68040 / 68040+68882 / MMU 68040
  (not in use)*, and WhichAmiga reads *MC68040, 68040fpu*.
* **Chip RAM**, TestROM2 with Chip Speed at Fast: **7.6 MB/s at 607 ns** an access — above
  Minimig's TG68K with its data cache on (5.9 MB/s, 899 ns) on both counts.

Chip-RAM accesses do not go over the Amiga chip bus. They go down the memory controller's own CPU port, where a cycle completes when SDRAM actually commits it rather than when arbitration says so. Agnus keeps absolute priority for DMA.

---

## Getting started

### Install

BigMig ships its own build of MiSTer's Main. **Install it as a second binary, not in place of
yours** — that way it runs only when you load BigMig, and the rest of your machine is untouched.

1. Copy `MiSTer_BigMig` from the release to `/media/fat/` — a **new file**, and it already
   carries the name it must have. Leave your official `/media/fat/MiSTer` alone.
2. Add this to `MiSTer.ini`:

```ini
[BigMig]
main=MiSTer_BigMig
```

| from the release | goes to |
|---|---|
| `BigMig_YYYYMMDD.rbf` | `/media/fat/_Computer/`, or the card root |
| `BigMig_YYYYMMDD.txt` | **beside the `.rbf`** |
| `Emu68.img` | `/media/fat/linux/Emu68.img` |
| `MiSTer_BigMig` | `/media/fat/` — **do not rename it to `MiSTer`** |
| `Scripts/bigmig_update.sh` | `/media/fat/Scripts/` |
| `BigMig_Guest_YYYYMMDD.hdf` | with your other hard-disk images, e.g. `/media/fat/games/Amiga/` |

Then put a Kickstart ROM where you already keep Minimig's.

The first four files are the machine. The `.hdf` is a small hard disk for the Amiga side: our
drivers, installed from inside the Amiga (see [The guest disk](#the-guest-disk)). None of it is
needed to boot. `bigmig_update.sh` is what the OSD's **Check Updates** row runs (see
[Check Updates](#check-updates)).

⚠ **Why a second binary.** BigMig is under active development. Keeping its Main separate means
nothing of ours runs unless you load BigMig: your official Main stays exactly where it is, the
updater keeps maintaining it, and the rest of your machine is untouched by whatever we change
next.

⚠ **The `.rbf`, its `.txt` and `Emu68.img` must be on the SD card.** Loading BigMig restarts the
board to hand the firmware its ARM core, and it is U-Boot that loads the core again — from the SD
card only. A core on a USB drive or a network share cannot be found there: BigMig's own Main
checks for this and says so on screen ([message 1](#bigmig-does-not-start)); loaded another
way, the board just restarts without saying why. Your data is another matter: hard-disk and CD
images, ADFs and games can live on a USB drive or a network share, because they are opened when
you mount them, long after the share is up. **Keep the Kickstart ROM on the SD card as well**: it
is read the moment BigMig starts, which can be before a network share has been mounted.

⚠ **The `.rbf` and the `.txt` must sit in the same folder and keep the same name.** The `.txt`
holds the Linux boot arguments that hand ARM core #1 to the firmware, and the loader finds it by
taking the core's own filename. Split them, or rename one without the other, and the core starts
with no CPU. **Keep the `.txt` exactly as released** — it is two lines now, and both matter.

⚠ **`Emu68.img` keeps that exact name**, in `/media/fat/linux/`. It is the firmware, not a disk
image.

⚠ **Do not mix releases.** Firmware and gateware are versioned and tested together; taking one
file from an older set is the first thing to undo if something behaves strangely.

⚠ **Linux version: stay on 5.15 for now.** BigMig is validated on MiSTer's **Linux
5.15.1-MiSTer**, and there Host Speed applies live. MiSTer release 20260912 moves to **Linux
6.18.38**, and the stock updater has offered it since 2026-09-14. BigMig has not been validated
on 6.18 yet, and one known change there is expected to affect it: the new CPU-frequency driver
switches off, during every change of the ARM clock, the clock that BigMig's CPU bridge runs on —
which is why, on a 6.x kernel, BigMig's Main applies a Host Speed change only at the next Reset.
If your card is on 6.18 (`uname -r` shows it) and BigMig misbehaves, say so in your report.
To stay on 5.15, set `update_linux = false` in the `[MiSTer]` section of `/media/fat/downloader.ini`
before you update — the Downloader discourages it, so turn it back on once BigMig supports 6.18.

### The sidecar, briefly

`BigMig_YYYYMMDD.txt` sits next to the `.rbf` and carries this core's Linux boot arguments —
`maxcpus=1` among them. It is the **official MiSTer per-core boot-args mechanism**, not something
we invented.

It exists because a core that hands an ARM core to a bare-metal JIT cannot have Linux
scheduling on that core. Loading BigMig reloads Linux with those arguments, so core #1 arrives
at the hybrid launch never having entered the new Linux instance at all. Loading any other core
reloads Linux without them, and that core gets its two CPUs back. That reload is why **the board
restarts once when you load BigMig** — it is normal.

The file has **two lines**. The first holds the arguments. The second protects them from a
`/linux/u-boot.txt` of your own: U-Boot reads that file after the core's `.txt`, and a `v=` line
in it — MiSTer's own example file has one — would otherwise replace BigMig's arguments. With the
second line your `v=` settings are kept and BigMig's are added to them, for BigMig's boot only.

⚠ Both files must be present. The `.rbf` without its `.txt` will not start correctly — see
[BigMig does not start](#bigmig-does-not-start).

### The guest disk

`BigMig_Guest_YYYYMMDD.hdf` carries everything BigMig puts inside the Amiga — our drivers, the
MiSTer Share handler, RiVA, BigMig's `mpega.library` and AHI 6 — laid out like `SYS:`, with an
installer.

1. On the OSD's **Drives** page, make sure **BigMig HDs Board** is On, put the `.hdf` in a free
   **Disk** slot, and Reset. It appears as **`BMG0:`**, volume **BigMig**, and it never boots,
   whatever slot it is in: it carries its own partition table, with one partition that is not
   bootable, so it cannot take the boot from your system disk, and its name cannot clash with
   your `DH0:` or `DH1:`.
2. Open it and double-click **Install** — or, from a Shell, `CD BigMig:` then `Execute Install`.
3. Reboot.

Install first looks at what your system already has, under any name, and **never replaces a
file of yours without asking**: your screen modes, network settings, icons and mountfiles stay
as they are. At the end it tells you only about what it did not find. Every slow step shows its
progress, so a pause is never a hang. Everything the window shows also goes to a log you can
send with a report: **`SHARE:BigMig-Install.log`** when the MiSTer Share is mounted, else
`RAM:BigMig-Install.log`. `Install.txt` on the disk explains each question, and how to answer
them in advance for a scripted install.

| on the BigMig disk | Install puts it in | for |
|---|---|---|
| `Devs/AHI/bigmigAHI.audio` + `Devs/AudioModes/bigmigAHI` | `SYS:Devs/AHI/`, `SYS:Devs/AudioModes/` | 16-bit sound — a pair, see [below](#16-bit-audio-the-bigmigahi-card) |
| `AHI6/` — AHI 6.0 | `SYS:Devs/`, `SYS:Prefs/`, … | AHI itself, only if you say yes — offered when yours is older or missing, see [below](#16-bit-audio-the-bigmigahi-card) |
| `Libs/Picasso96/ZZ9000.card`, `Devs/Monitors/ZZ9000`, `Devs/Picasso96Settings` | `SYS:Libs/Picasso96/`, `SYS:Devs/Monitors/`, `SYS:Devs/` | RTG — BigMig's screen modes are copied only when you have none; yours with ZZ9000 modes stay; for yours without them it asks (Replace keeps yours as `Picasso96Settings.pre-BigMig`) |
| `Devs/Networks/ZZ9000Net.device`, `Devs/NetInterfaces/ZZ9000Net` | `SYS:Devs/Networks/`, `SYS:Devs/NetInterfaces/` | Ethernet — the device replaces only an older one; the interface file is a sample to edit, copied only when you have none |
| `Devs/DOSDrivers/CD0` … `CD3` | `SYS:Devs/DOSDrivers/` | the four CD drives |
| `Libs/mhi/mhibigmig.library` | `SYS:Libs/mhi/` | MP3 decoding for MHI players |
| `L/MiSTerFileSystem`, `Devs/dummy.device`, the `SHARE:` entry | `SYS:L/`, `SYS:Devs/`, your `SYS:Devs/MountList` | the MiSTer Share — and, if you say yes, a short block in `S:User-Startup` mounts it at every boot |
| `Utilities/RiVA` | `SYS:Utilities/` | MPEG-1 video (below) |
| `mpega/mpega.library` | `SYS:Libs/`, if you say yes | MP3 decoding in software (below) |
| `WheelDriverAkiko/` | `SYS:WBStartup/`, `SYS:C/`, if you say yes | a wheel mouse, and Akiko's C2P (below) |

Install never replaces your `MountList` or your `User-Startup`. It puts the `SHARE:` entry
**first** in your `MountList` — Mount takes the first entry of a name — keeping your file once as
`MountList.pre-BigMig`, and it repairs what an older Install's append did to your last entry,
with a small tool of its own, `Tools/BigMigFixMountList`, never an editor. If it finds no mount
of `SHARE:` at boot, it asks before adding one at the end of `S:User-Startup` (your file is kept
once as `User-Startup.pre-BigMig`): a block marked `BEGIN BigMig` … `END BigMig` that only tests
that its files exist and mounts `SHARE:` in the background. Delete the block to undo it, or
switch it off without editing anything — see [The MiSTer Share](#the-mister-share).

The `ZZ9000.card` it installs is version 2.8, which hands blitter work to the firmware as a queue
instead of waiting on each operation. The 2.6 driver goes in beside it as `zz9000card.26` —
rename it over `ZZ9000.card` to go back. A `ZZ9000.card` that is not BigMig's is replaced only if
you say so (yours is kept as `ZZ9000.card.pre-BigMig`).

**RiVA** plays MPEG-1 video in any CPU mode: it uses OMMX when OMMX is ON and the plain 68k code
otherwise — one program, which picks at start. Install replaces an older BigMig RiVA, asks
before replacing anyone else's (yours is kept as `RiVA.pre-BigMig`), and keeps an icon you
already have. Its sound needs AHI and an `mpega.library`. Its tooltypes (PRI, ASYNCPRI,
AUDIOPRI, RESYNC), credits, licence and source are in `Utilities/RiVA-README.txt`.

**BigMig's `mpega.library`** (in `mpega/`) decodes MP3 in software, for RiVA and for players
that use it. It runs in every CPU mode — 68EC020 with or without the 68882, 68040, 68060+ — and
its synthesis uses OMMX when OMMX is ON, the plain code otherwise. Install offers it: with no
`mpega.library` it asks to install it; another one in `SYS:Libs` it replaces only if you say so
(yours is kept once as `mpega.library.pre-BigMig`); an older BigMig build it updates by itself.
Credits and licence: `mpega/README-mpega.txt`.

**The Minimig extras** in `WheelDriverAkiko/`, Alastair M. Robinson's, as Minimig for MiSTer
ships them: WheelDriver and FreeWheel make a wheel mouse scroll, and go to `SYS:WBStartup`;
SetAkiko points graphics.library at Akiko's C2P, goes to `SYS:C` and runs at every boot from a
second block at the end of `S:User-Startup` (`BEGIN BigMig Akiko` … `END BigMig Akiko`). Install
offers only the ones you do not have, looking for yours under any name. SetAkiko does not check
for Akiko: if the same system also boots on an Amiga without Akiko's C2P (a PiStorm, a real
A1200), create a file `S:NoBigMigAkiko` there and the block skips it. SetAkiko's C2P has not been
verified on BigMig yet.

Also on the disk, not installed:

* `Tools/jitstat` — prints the JIT's counters (see [Emu68 guest tools](#emu68-guest-tools)).
* `Tools/BigMigFixMountList` and `Tools/BigMigFileID` — the two tools Install runs; `Install.txt`
  says how to run them yourself.
* `AHI6/Devs/AHI/toccata.audio` — the Toccata card's AHI driver, for a system disk that also
  boots Minimig with its Toccata. BigMig has no Toccata, so Install copies it only if you say
  yes: without the Toccata software the driver opens a "Cannot open toccata.library" requester
  whenever AHI lists its modes.

`Contents.txt` on the disk lists the version and checksum of every file.

⚠ **Not provided by the BigMig disk** — Install tells you when it does not find these on your
system:

* **Picasso96.** The guest disk carries every ZZ9000 RTG file, but the RTG *system* those files
  plug into is Picasso96, which you install first. The last freely distributable version is
  **Picasso96 2.0** on Aminet:
  [`driver/video/Picasso96.lha`](https://aminet.net/package/driver/video/Picasso96).
* **A TCP/IP stack** for the network — Roadshow, AmiTCP… (one you start by hand counts).
* **A `68060.library`** for the 68060+ mode — MMULib's, on Aminet:
  [`util/libs/MMULib.lha`](https://aminet.net/package/util/libs/MMULib).
* **MUI**, which AHI Prefs 6 needs.

### Where the settings live

The split is deliberate: the **processor** has its own pages, the **machine** another.

**Emu68-A9** — Mode, **JIT Settings**, 68882, FPU ROM, OMMX, Host Speed, Chip Speed, Chip Cache.
Everything that describes the CPU you are running. **JIT Settings** opens a page of its own:
Preset, Guest Req, JIT Cache, JIT Depth, JIT Poll, Slow Chip, Slow DBF, CCRD scan, Blt Pace,
InnerLoop, LCNT.

**System** — Chipset and RAM, then **Zorro Boards**: ZZ9000 RTG, ZZ9000 Network, BigMig AHI/MHI,
Emu68 DevTree.
Then the usual Joystick, ROM and HRTmon.

**Drives** — the BigMig HDs board switch, four **Disk** slots for hard-disk and CD images, and
Floppy Disk Turbo.

The main page also carries **Check Updates**, between Save configuration and Reset.

Every setting is saved with the config slot, so a slot can be a whole machine: a 68040 with the
RTG and no sound for one title, an 020 with everything for another.

**When a change takes effect.** Everything on the JIT Settings page, Chip Cache and Host Speed
apply at once — Host Speed at the next Reset on a Linux 6.x kernel. Mode, 68882, FPU ROM, OMMX
and Chip Speed wait for a Reset — touch one and a **Reset (apply changes)** row appears at the
foot of the page. The Zorro boards and the hard-disk slots wait for a Reset too.

⚠ **On a board, OFF means ABSENT, not idle.**  The card leaves the autoconfig chain entirely and
the firmware stops spending anything on it, so the guest never sees it and the emulation core
never pays for it.  That is the point: a configuration should not be taxed for hardware it does
not use.  The exception is ZZ9000 Network, whose bridge runs on the Linux core and which
therefore applies the instant you press it; everything else takes effect at the next Reset.

### The processor: Mode, 68882, FPU ROM, OMMX

The Emu68-A9 page, saved per config:

* **Mode: 68EC020 / 68040 / 68060+.** The personality is honest in every direction: as an 020
  the 68040-only instructions trap exactly as they should (WHDLoad's CPU probe depends on it); as
  an 040 the MOVEC register set, the cache instructions, PFLUSH/PTEST and the 040 stack frames
  are all answered — that is what SysInfo and WhichAmiga identify. **68060+** presents a 68060 —
  its PCR reads as a revision-6 part, and it saves the 060's own FPU state frame — but, unlike
  the real chip, it deprecates nothing: MOVEP, the 64-bit MUL/DIV forms, CAS2 and the FPU's
  transcendental instructions, which Motorola moved to software on the 060, all still run
  natively. **68040** is the one we recommend — the row calls it the default — though a new
  config still starts as a 68EC020. The guest latches its CPU identity at boot, so the mode
  changes at the next Reset.

  **Why the 68040 and not the 68060+.** The 68060+ is the right choice for software written for
  the 060: it sees a 060 and takes its 060 code paths. But it asks more of the system around it —
  AmigaOS wants a `68060.library` in `LIBS:` (below), and a few programs that know the 040 but not
  the 060 misbehave on it (Mac OS 8.1 under ShapeShifter, below). The 68040 needs nothing extra on
  the disk — with FPU ROM ON the firmware answers for `68040.library` itself — and every program
  that runs on a 060 but also knows the 040 runs on it. On BigMig both are the same JIT at the same
  speed; what changes is only what the software sees.

  ⚠ Under 68060+, AmigaOS expects a `68060.library` in `LIBS:`, as on a real 060 — MMULib's,
  for instance. It is what saves the FPU registers between tasks.

  ⚠ Mac OS 8.1 under ShapeShifter runs with Mode at **68040**; under 68060+ it fails shortly
  after reaching the Finder. Mac OS 7.5.5 runs under both.
* **68882: ON / OFF.** A 68882-class FPU computing in double precision. Under the 68040 and the
  68060+ the row is locked ON — both carry their FPU on-chip.
* **FPU ROM: ON / OFF.** A small ROM board of ours that, as the system starts, points AmigaOS's
  maths libraries — the IEEE single- and double-precision libraries and the Motorola FFP
  transcendentals — at FPU instructions the JIT runs natively. Software that does its maths
  through the libraries, rather than with FPU code of its own, gets the FPU without being
  rewritten: a double-precision transcendental test went from 47.9 s to 2.3 s. Under the 68040
  it also answers for `68040.library`, so SetPatch does not load one from disk; under the 68060+
  it keeps your `68060.library`.
* **OMMX: ON / OFF.** An open SIMD extension for this machine; the Apollo **AMMX** instruction
  set is a strict subset, so existing AMMX software (RiVA's video kernels, for instance) runs
  unmodified.  Each Amiga task keeps its own OMMX registers — the firmware saves and restores
  them as exec switches tasks, for up to 64 tasks that use OMMX — so two OMMX programs, a video
  player and an MP3 decoder say, run side by side.  The spec is open, and worked examples exist.
  A caveat worth knowing before porting code: OMMX buys *arithmetic* throughput; a display path
  that is memory-bound gains nothing, and we publish the measurements that show it.

### Host Speed, Chip Speed and Chip Cache

* **Host Speed: 800 MHz / 1000 / 1200.** The clock of the DE10-Nano's ARM cores — Linux's and
  the JIT's alike, so the Amiga speeds up with it. 800 MHz, the board's standard clock, is the
  default. It is saved per config slot and applies at once — on a Linux 6.x kernel it is saved
  and applied at the next Reset or core load instead, and the row says so. If a saved overclock
  ever stops the board from starting, the next start falls back to 800 MHz by itself.

  ⚠ **Use active cooling, always** — even at the standard 800 MHz. **1000 and 1200 are an
  overclock: it comes with no warranty, and you do it at your own risk.**
* **Chip Speed: Fast (AGA) / Compat (68000).** Fast, the default, lets the CPU reach chip RAM
  through a direct window — about 3.5 times an A600. Compat brings chip-RAM access down to
  roughly a 68000's pace, for OCS/ECS software that times itself against it. It applies at the
  next Reset. It is a different brake from the JIT page's Slow Chip: this one slows every
  chip-RAM *access*, Slow Chip every instruction *executed from* chip RAM; together they add up.
* **Chip Cache: ON / OFF.** The FPGA's cache for the CPU's reads of chip RAM. ON, the default,
  is the fast setting; OFF is only for diagnosis. It switches live.

### JIT Settings

Every row on this page applies **live**: the popup says *applied* when the firmware confirms it,
or *queued* when it did not, and then the next Reset applies it.

**Preset** sets the rest of the page in one go:

| preset | what it sets |
|---|---|
| **MAX SPEED AUTO** | full speed — JIT Depth 256, JIT Poll 32, JIT Cache Normal, LCNT 8, no brakes — with **Guest Req: Accept**. A new config starts here. |
| **MAX SPEED** | the same, with **Guest Req: Ignore**. |
| **ECS LEGACY COMPAT** | upstream Emu68's usual recipe for old software, at a depth of 14: JIT Cache Verify (NoCache), Slow Chip SC (SCS=1), Slow DBF ON, CCRD scan 0, LCNT 2, Guest Req: Ignore. |
| **CUSTOM** | your own values, every row of the page included. They are remembered when you step to a preset and restored when you come back to CUSTOM, for as long as the core runs. |

Every preset also sets Blt Pace to Tuned and InnerLoop ON. Change a row by hand and the preset
reads CUSTOM; dial a preset's values in by hand and it reads that preset's name.

**Guest Req: Accept / Ignore** — whether the guest's own requests reach the JIT. With
**Accept**, a title that switches its caches off — a WHDLoad `NOCACHE` tooltype, EmuControl —
runs under Verify at depth 2 for as long as they stay off, and EmuControl's settings apply; the
rows they change are tagged **(Guest)**. With **Ignore** the OSD's values always rule. Touching a
row, or a reset, puts the OSD's values back.

**JIT Cache** — what happens when a program rewrites code:

| setting | what it does |
|---|---|
| **Normal (Default)** | When a program announces that it rewrote code (a cache flush), the translations are marked, and each one is checked once, the next time it runs: kept if unchanged, redone if not. Unchanged code is never translated twice. This is upstream Emu68's default too. |
| **Hard Flush** | Every announced flush throws every translation away. The older, simpler behaviour — much slower on systems that flush often, such as Mac OS under ShapeShifter. |
| **Verify (NoCache)** | Every translation is checked every time it runs, announced or not — for demos and WHDLoad titles that rewrite their own code without saying so. Much slower. It is what upstream Emu68 does for a WHDLoad `NOCACHE`. |

**JIT Depth** — how many m68k instructions go into one translated unit. 256, the default, is the
fastest; lower values return to the dispatcher more often, which shortens the guest's interrupt
latency for timing-fragile demos, at a cost in speed. **JIT Poll** — how many unit exits pass
between checks for a pending interrupt; 32 is the default, and the worst-case latency is
Depth × Poll.

**Slow Chip**, **Slow DBF** and **CCRD scan** are upstream Emu68's own compatibility levers,
under their own names (`SC`/`SCS`, `DBF`, `CCRD`). Slow Chip adds a chip-bus read before every
*n*-th instruction executed from chip RAM; Slow DBF slows the `dbf` busy loops old music replayers
use; CCRD scan is how far ahead the flag optimiser looks, and 0 turns it off. Code running in fast
RAM pays nothing for Slow Chip or Slow DBF. So a community recipe maps straight across:
`ICNT=2 NOCACHE SC` is JIT Depth 2, JIT Cache Verify (NoCache) and Slow Chip SC (SCS=1).

**Blt Pace** — how long a program that polls the blitter is held on each check while the blitter
is busy, so that the blitter gets the bus. **Tuned (Default)** is the firmware's own pace, which
lasts the same time at every Host Speed; **Off** never holds; 0.5 to 24 µs set it by hand.

**InnerLoop** — **ON (Default)** runs a tight loop inside its translated unit; OFF sends every
pass back to the dispatcher, as older firmware did. It is there for testing.

**LCNT** — upstream Emu68's inline loop count: how many copies of such a loop's body one
translated unit holds, so each pass runs that many iterations. **8 (Default)** is upstream's
value and the most copies; 4 and 2 hold fewer; 1 runs one iteration per pass. Under ECS LEGACY
COMPAT the row offers only 2, that preset's value, and 1, and both keep the preset: under its
Verify no loop runs inside a unit, and larger values measured slower there.

If something behaves oddly, **try the default again before reporting it**, and tell us which
settings you used.

### RTG: the ZZ9000

The RTG card is a model of MNT's **ZZ9000**, with its blitter running natively on the ARM. It
needs Picasso96 (see [The guest disk](#the-guest-disk)); after that, setting up Workbench for it
is the same as setting it up for Minimig's own MiSTer RTG card.

* **HDMI** carries every RTG mode, up to 1920×1080, through MiSTer's scaler.
* **The analog output** carries RTG modes up to 640×480 at a real monitor rate, straight from
  the framebuffer rather than through the scaler: up to 360×288 at **15 kHz / 50 Hz** — what an
  Amiga monitor, a TV or an OSSC locks to — and up to 640×480 at **31 kHz / 60 Hz**, VGA. The OSD
  shows on it too. Taller modes are HDMI only: the analog output goes dark for them, unless
  `vga_scaler=1` in `MiSTer.ini` sends the scaled picture there. Packed 24-bit modes are not
  carried.
* **The mouse pointer** on an RTG screen is drawn by the FPGA over the picture, on HDMI and on
  the analog output alike, instead of being painted into video memory. Over native chipset video
  the Amiga's own sprites draw it, as always.
* **Which picture is on screen** is in the OSD's title — **BigMig (RTG)**, **(AGA)**, **(ECS)**
  or **(OCS)** — and in a short tag whenever it changes.

**Known issue.** Now and then the RTG picture comes up garbled after a screen-mode switch. A Reset
does not clear it; loading the core again from the OSD (**Load core**) does, with no need to power
off.

### Ethernet

The ZZ9000's **network function** is implemented alongside its graphics: the stock
`ZZ9000Net.device` driver finds a wired card and reaches the real LAN.  The bridge runs on the
Linux core at the **lowest priority in Main's loop** — input, the OSD, audio and disk always come
first — and the OSD **ZZ9000 Network** row prices it honestly: OFF costs literally nothing (the
socket is never opened), ON costs about half a percent.  It is the one row that applies live — its
bridge is a Linux-side process, so switching it is the cable coming and going as far as the
guest is concerned.

The guest negotiates DHCP, resolves its gateway by ARP, and answers pings from other machines
on the LAN.  The card presents its own MAC address, so a stock driver and a stock TCP/IP stack
are all it needs — you supply the stack (Roadshow, AmiTCP), the core supplies the card.

### 16-bit audio: the bigmigAHI card

Paula is four DMA voices of 8-bit PCM, and AHI's own `paula.audio` reaches about **14 bits** on
two of them by pairing channels at different volumes.  That is more than the chip is usually
given credit for, and it is still the machine's ceiling for modern work: the pairing costs half
the voices, the mixing is done by the 68k, and MP3 playback or a tracker wanting true 16-bit
output has nowhere to go.  So the core carries a 16-bit sound card of its own, **bigmigAHI**,
and the AHI sub-driver that binds it.  The card is the **BigMig AHI/MHI** row on the System page.

It is not an emulation of anyone else's board.  The card model and the mixing both run on the
firmware core, which leaves the Linux core free to serve the guest's disk and file requests —
music keeps playing while you open a drawer.  The card takes 8 independent streams of 16-bit
stereo, and the mixing arithmetic happens on the ARM, not on the emulated 68k: a Workbench
application hands the card a buffer and goes back to its own work.  Its output mixes with Paula's into whatever the MiSTer
framework outputs, so a game using Paula and a player using AHI coexist.

Two files make it work, and **they are a pair — either one alone does nothing**:

| file | goes to | what it is |
|---|---|---|
| `bigmigAHI.audio` | `DEVS:AHI/` | the AHI sub-driver |
| `bigmigAHI` | `DEVS:AudioModes/` | the mode descriptor AHI reads to offer the card |

Without the mode file AHI offers nothing and the driver is invisible to applications.  Both are
on the guest disk, and Install puts them in place.  ⚠ AmigaOS matches library names
**case-sensitively** once resident, so the capitalisation above is functional, not cosmetic.

**AHI itself** is not part of AmigaOS 3.1 or 3.2. The guest disk carries **AHI 6.0**, and Install
offers it when your `ahi.device` is older or missing; an AHI 6 you already have, or one outside
`SYS:Devs`, is left alone. Your old `ahi.device`, AHI prefs program and settings are kept first as
`ahi.device.418`, `Prefs/AHI.418` and `ENVARC:Sys/ahi.prefs.418`; to go back, copy the three over
the new ones and reboot. After the update, reboot, open **Prefs/AHI**, choose the modes again and
Save: AHI 6 keeps its settings in a new format. AHI Prefs 6 needs **MUI**, which the BigMig disk
does not provide.

### MP3: MHI

MHI is the standard Amiga interface for hardware MP3 decoders: a player that supports it —
AmigaAMP, for one — hands the decoding to the card instead of doing it on the 68k. On BigMig the
card is the ARM. `mhibigmig.library` passes the MP3 data to the firmware, the Linux core decodes
it, and the sound comes out with Paula's and bigmigAHI's.

In AmigaAMP — the player it has been tested with — pick `mhibigmig.library` in its MHI settings.
⚠ It must be in `LIBS:mhi/`, where Install puts it — AmigaAMP remembers only the file name.

The decoder lives on the ZZ9000 board, as it does on the real card, so it needs **ZZ9000 RTG**
ON; ShowConfig shows no separate board for it. It also follows the System page's **BigMig
AHI/MHI** switch: OFF, and the player falls back to its own decoder.

Having MHI does not make it the fastest way to play MP3 on BigMig. With **OMMX** ON, a player that
decodes in software through BigMig's own `mpega.library` — whose synthesis runs on OMMX, and which
Install offers — can be even faster. MHI's strength is that the decoding happens off the 68k.

### Hard disks

`bigmigHD.device` serves the four **Disk** slots of the Drives page to the Amiga as hard disks,
and autoboots from them. It takes:

* **HDF images** with an RDB, as HDToolBox makes them — plain images only; WinUAE's dynamic and
  sparse HDF formats are not supported.
* **Single-partition images** without an RDB (`.hdf`, FFS): BigMig builds the missing RDB around
  them as they mount.
* **PiStorm/Emu68 SD-card images** (`.img`), as the distributions ship them: BigMig finds the
  Amiga disk inside the card's partition table and mounts it untouched. CaffeineOS boots this
  way, with Emu68 DevTree OFF, the default (see *PiStorm and Vampire distributions*).

Disk changes apply at the next Reset. The Drives page's **BigMig HDs Board** switch must be On —
a new config starts with it Off — and Off removes the board altogether.

### PiStorm and Vampire distributions

BigMig boots distributions made for the PiStorm (Emu68) and the Vampire — CaffeineOS and Coffin
among them — from their own images, as they come (see *Hard disks*). We added this so that the
content they carry — demos, games, WHDLoad installs — is within easy reach. But these
distributions are prepared for hardware that is not ours: with BigMig's drivers installed they
work, yet it is much better to wait for their authors to make BigMig versions of them, or to build
systems closer to what the MiSTer is. If you run one, four things to know:

* **CPU Mode.** PiStorm's Emu68 presents itself as a 68040, and CaffeineOS is built for that:
  set **Mode** to **68040** on the Emu68-A9 page for it.
* **Two boots, and our Install.** PiStorm distributions load Emu68's Raspberry Pi video driver,
  `Devs:Monitors/emu68-VideoCore`, at startup, and on BigMig it hangs. Boot the **first time
  with Emu68 DevTree OFF**, only to take that driver away: delete it, or move it out of
  `Devs:Monitors`. Then set **Emu68 DevTree ON** and, on the **second boot**, run **Install**
  from the guest disk (see *The guest disk*): it patches the distribution with BigMig's drivers.
  **Our Install is what makes these distributions run reasonably well on BigMig** — as they
  come, they are built around hardware BigMig does not have.
* **Coffin: OMMX OFF the first time.** When Coffin boots with a Kickstart that is not its own,
  its `S:Startup-Sequence` runs Apollo's `ApolloMap` to write `DEVS:Kickstarts/coffin.rom` into a
  Vampire's ROM and restart. ApolloMap takes BigMig for a Vampire because OMMX runs the Apollo
  instruction it tests for, and writing into BigMig's ROM stops the machine. So boot Coffin the
  **first time with OMMX OFF** — ApolloMap then sees no Vampire and gives up — put a `;` in front
  of the `C:ApolloMap` line in `S:Startup-Sequence`, set **OMMX ON** again, and run our
  **Install** as above.
* **They run, but they are not polished yet.** BigMig mounts these images and runs them, but
  some things in them do not yet work as they should, and many of the tools they carry cost
  performance on BigMig: frequent interrupts, and above all cache flushes — on a JIT each flush
  throws translated code away. In our own comparison, CaffeineOS felt slower than a Workbench
  3.2.3 set up for BigMig — ZZ9000 RTG, bigmigAHI, the JIT presets — at the same resolution and
  with similar effects.

  We keep working to make them run better. But the good path is a system built on a modern
  AmigaOS 3.2.x, with the few tools that improve the experience without weighing it down: from a
  distribution, bring its content across rather than its whole system.

### CD drives

Up to four, and they behave like real drives rather than like files.

Put a `.iso`, `.cue` or `.chd` into one of the four **Disk** slots on the OSD's **Drives** page.
The extension is enough — there is no mode to set. Each slot is its own drive:

| slot on the Drives page | drive |
|---|---|
| Disk 0 | `CD0:` |
| Disk 1 | `CD1:` |
| Disk 2 | `CD2:` |
| Disk 3 | `CD3:` |

The guest disk's Install puts all four mountfiles in `DEVS:DOSDrivers/` — a `CD0`…`CD3` of your
own that does not name `bigmigHD.device` is left as it is — and a slot without a CD in it is
simply an empty drive. They need `L:CDFileSystem`, which comes with Workbench; it is not
ours to ship. Data only — CD audio is not played.

★ **A drive is permanent; the image is the disc.** Each `CDn` describes a drive that exists
whether or not anything is in it, so the mountfile is written once and never edited again.
Re-opening the slot with a different image *is* changing the disc: the drive's change counter
moves, the guest's drive task notices within a second and tells the file system. **No reset.**
Hard disks are not like this and still need one — pulling an FFS volume out from under a running
guest would take its cached state with it — so a CD image put into a slot that holds a hard disk
waits for the Reset as well.

⛔ **`bigmigHD.device`, with a capital H and D.** exec's `FindName` compares exactly, so
`bigmighd.device` opens nothing — and it fails *silently*, looking exactly like a broken file
system. The shipped mountfiles have it right; this only bites if you write your own.

### The MiSTer Share

`SHARE:` is a MiSTer folder that the Amiga sees as a drive: `games/Amiga/shared`
by default, or the folder that `shared_folder=` names in `MiSTer.ini`. The guest disk's Install
sets it up and, if you say yes, mounts it at every boot — in the background, and only when its
files are there, so a share that is not there never holds up a boot.

To switch that boot mount off without editing anything, create a file `S:NoBigMigShare` — from a
Shell, `Echo >S:NoBigMigShare "off"` — and delete it to mount `SHARE:` again. If a boot ever stops
because of `SHARE:`, hold both mouse buttons while the Amiga resets, choose **Boot With No
Startup-Sequence**, type that same line and reset again. In a startup file of your own, always
put `Run` in front of a `Mount SHARE:`: without it, Mount waits for the share, and a failure stops
the script.

On BigMig the file data takes a fast path: the Main reads and writes straight into the Amiga
program's own buffer, and a large copy runs at about 3 MB/s. The handler is Minimig's with that
path added; on a standard Minimig it uses the classic path by itself. So Install replaces the
official Minimig for MiSTer handler and BigMig's older builds with it (the file before is kept
once as `MiSTerFileSystem.pre-BigMig`), leaves the same or a newer BigMig build, and asks about
one it does not know.

---

### Emu68 guest tools

The firmware speaks Emu68's own guest interface — the telemetry and control registers, and
`devicetree.resource` — so tools written for Emu68 run here without a port.

`devicetree.resource` comes from a small Zorro board of its own, **Emu68 DevTree** on the System
page. It is **OFF by default** and, like every board, takes effect at the next Reset. Emu68Info
and the other Emu68 tools need it ON.

⚠ **PiStorm/Emu68 distributions (CaffeineOS, for one) and DevTree.** Their startup loads
Emu68's VideoCore monitor driver, `Devs:Monitors/emu68-VideoCore`. That driver takes
`devicetree.resource` as proof that it runs on a Raspberry Pi; BigMig's tree has no VideoCore
in it, so the driver waits for the Pi's graphics chip forever and the boot stops at a black
screen. So, for such a distribution:

1. Boot it the first time with **Emu68 DevTree OFF**.
2. Delete the driver, or rename it or move it out of `Devs:Monitors`.
3. Set **Emu68 DevTree ON** and Reset — Emu68Info and the other tools now find the resource.
   On that boot, run our Install (see *PiStorm and Vampire distributions*).

* **Emu68Info** — Philippe Carpentier's, from the Emu68-tools collection — reads the firmware's
  identity, the JIT and its counters, and the loaded modules. The parts that describe a
  Raspberry Pi have nothing to show here, and **HARDRESET must not be used** — it drives Pi
  hardware that BigMig does not have.
* **jitstat**, in `Tools/` on the guest disk, prints the same registers from a Shell.
* **EmuControl** — Michal Schulz's, from the same collection — reaches the JIT when **Guest Req**
  is Accept; the rows it changes show **(Guest)** on the JIT Settings page.

The JIT's counters are always on.

### Check Updates

**Check Updates**, on the main OSD page, asks our public repository whether a newer BigMig
release is out — Main, core, `.txt` and firmware, as one set — and, if there is one, offers to
install it from a console window. It installs the set whole or not at all. It writes only
BigMig's own files — never your official `MiSTer`, `MiSTer.ini`, Linux, U-Boot or your
`linux/u-boot.txt` — and it keeps the files it replaces in a backup folder, `.bigmig_backup` on
the card (the last two updates).

* **The `.txt`** beside the core is replaced when it is one we published. If you changed it,
  Check Updates tells you there is a new one and asks before replacing it; if you keep yours,
  the release's copy waits in the backup folder.
* **A new guest disk** is downloaded beside your other hard-disk images under its own dated name,
  never over the one you have — that one may be mounted. Mount the new one and run its Install.
* **The core** is found in `_Computer/` or the card root, where the table above puts it.

It needs `Scripts/bigmig_update.sh` from the release on the card, a network connection and a set
clock.

---

## BigMig does not start

Loading BigMig restarts the board once, so that Linux comes back up on one ARM core and leaves
the other to the firmware (see [the sidecar](#the-sidecar-briefly)). If that did not happen,
BigMig cannot start its CPU, and the OSD says why for ten seconds. The same diagnosis goes, as one
line starting with `[boot-diag]`, into **`/media/fat/emu68_boot.log`** — the file at the root of
the SD card to send us with a report (the previous attempt's is kept as
`emu68_boot.log.prev`).

Each message below is exactly what appears on screen.

**1 — the core is not on the SD card.**

```
BigMig can't start:
its core is not on the SD.
U-Boot loads BigMig from the
SD card only (not from USB
or a network share).
Copy BigMig .rbf + .txt to
the SD, e.g. _Computer/
```

The `.rbf` is on a USB drive or a network share. The restart that gives the firmware its core
goes through U-Boot, and U-Boot reads only the SD card. Copy the `.rbf` and its `.txt` to the SD
card — `/media/fat/_Computer/`, say — and load BigMig from there. `Emu68.img` must be on the SD
card too; your disk images can stay where they are.

**2 — the `.txt` is missing.**

```
BigMig can't start:
its .txt is missing.
Put <BigMig_YYYYMMDD.txt>
next to the .rbf (same
folder, same name), then
load BigMig again.
```

There is no `.txt` beside the `.rbf` under the same name — it was not copied, or one of the two
was renamed. The message names the file it looked for (a name longer than 25 characters is
shortened with `...`). Put the release's `.txt` next to the `.rbf`, named like it, and load
BigMig again.

**3 — the `.txt` has no `maxcpus=1`.**

```
BigMig can't start:
its .txt has no maxcpus=1.
Use the .txt from the BigMig
release, unchanged.
```

The `.txt` is there, but its `v=` line does not carry `maxcpus=1` — it was edited, or it is not
BigMig's. Replace it with the one from the release and leave it as it is.

**4 — `/linux/u-boot.txt` overrides it.**

```
BigMig can't start:
/linux/u-boot.txt sets v=
and drops the maxcpus=1.
Remove the v= line from
u-boot.txt, or see README:
"BigMig does not start".
```

Your `/linux/u-boot.txt` has a `v=` line — MiSTer's example file has one, for faster USB polling
— and U-Boot reads it after the core's `.txt`, so it replaced BigMig's arguments. The `.txt` of
this release, and MiSTer_BigMig when it does the restart itself, normally keep your `v=`
settings and add `maxcpus=1` to them, so this message means that even that protected restart did
not work. Remove the `v=` line from `/linux/u-boot.txt`, and check that the `.txt` beside the
`.rbf` is this release's two-line file.

**5 — the restart did not take effect.**

```
BigMig can't start: the
restart with its .txt did
not take effect.
See the README, section
"BigMig does not start".
```

BigMig restarted the board to apply its arguments, but Linux still came up on both cores; none
of the checks above found why. Make sure the `.rbf`, the `.txt`, `Emu68.img` and `MiSTer_BigMig`
all come from the same release, unmodified, and load BigMig again from the core list. If the
message comes back, send us `emu68_boot.log`.

**6 — Linux kept both cores.**

```
BigMig can't start: Linux
started with both ARM cores
(maxcpus=1 was not applied).
Load BigMig from the OSD
core list, or see README:
"BigMig does not start".
```

Linux came up on both cores and none of the specific causes above applies. Load BigMig from the
OSD's core list; if the message comes back, send us `emu68_boot.log`.

⛔ **Do not put `maxcpus=1` in `/linux/u-boot.txt`.** If you added it to get an earlier release
running, take it out: that file applies to **every** core, so each of them would run Linux on one
ARM core instead of two, and official cores can stall that way. BigMig's `.txt` gives
`maxcpus=1` to BigMig alone.

---

## Reporting something that does not work

This core is new and it will have gaps. Reports are genuinely useful — but only if we can
reproduce them. Please include:

1. **Which release** — the date in the `.rbf`'s name
2. **Kickstart** version used
3. **Workbench** version used
4. **Mode** (68EC020, 68040 or 68060+) and the **JIT configuration** — the JIT Settings preset,
   or "defaults"
5. **WHDLoad** — *with its version* — or the **ADF** used
6. **What happened**, and a **snapshot** if there is anything to see

If BigMig did not start at all, send `/media/fat/emu68_boot.log` instead (see
[BigMig does not start](#bigmig-does-not-start)). If it is about the guest disk's Install, send
its log, `SHARE:BigMig-Install.log` (or `RAM:BigMig-Install.log`).

The WHDLoad version matters more than people expect: one class of failure we chased for days
turned out to be a 1999 install against a 2023 one.

---

## Credits and licences

BigMig stands on other people's work, and most of the Amiga in it is theirs.

| part | authors | licence |
|---|---|---|
| **Minimig** — the original FPGA Amiga | Dennis van Weeren, Jakub Bednarski, Tobias Gubener, Sorgelig (Alexey Melnikov), Rok Krajnc and contributors | GPLv3 |
| **MiSTer framework** (`sys/`) | Sorgelig (Alexey Melnikov) and the MiSTer-devel project | GPLv3 |
| **Minimig Hybrid** — the first hybrid Minimig, and the original seam register blocks | Mark Watson | see the Minimig Hybrid project |
| **Emu68** — the JIT this port descends from | Michal Schulz | see the Emu68 project |
| **Emu68-A9** — the ARMv7 / Cortex-A9 port of Emu68 | Ruben Aparicio (@raparici) | as Emu68 |
| **bigmigHD.device** and its autoboot ROM | Ruben Aparicio (@raparici), derived from Michal Schulz's `brcm-sdhc.device` and Emu68rom | MPL 2.0, as the originals |
| **ZZ9000** — the RTG driver, and the video formatter our analog RTG scan-out is ported from | MNT Research / Lucie L. Hartmann and contributors | see the ZZ9000 project |
| **The seam** — `axi_seam_slave`, `seam_engine`, `seam_ipl`, `seam_cpuregs`, `h2f_axi3_to_lite`, the hybrid bridge | Ruben Aparicio (@raparici) | GPLv3 |
| **RTG analog scan-out and pointer overlay** — `rtg_ddr_reader`, `rtg_scanout`, `rtg_sprite_overlay`, `rtg_hdmi_osd_sprite` | Ruben Aparicio (@raparici); `rtg_scanout` is ported from the ZZ9000's `video_formatter` | GPLv3 or later |
| **bigmigAHI** — the card model and `bigmigAHI.audio` | Ruben Aparicio (@raparici) | our own; source not published yet, so no licence yet |
| **mhibigmig.library** | Ruben Aparicio (@raparici), after the ZZ9000's own MHI driver | MIT |
| **minimp3** — the MP3 decoder behind MHI | lieff and contributors | CC0 (public domain) |
| **MiSTer Share handler** (`MiSTerFileSystem`) | Sorgelig (Alexey Melnikov), from Niklas Ekström's a314 original; the fast path is ours | see Minimig for MiSTer |
| **mpega.library** — BigMig's build, on the guest disk | Sigbjørn "CISC" Skjæret's libmad-based clone, with Jarmo Laakkonen and Stephan Rupprecht; libmad by Underbit Technologies (Robert Leslie); the OMMX synthesis and the one build for every CPU mode are ours | GPLv2 or later (libmad) |
| **RiVA** — the MPEG-1 video player on the guest disk | Stephen Fellner, with László Török and the Apollo Team; Henryk Richter (bax) — the rework, AMMX and the audio; BigMig's changes (OMMX or the 68k code in one program, the shutdown and AHI fixes) by Ruben Aparicio (@raparici) | GPLv2 — source: `Utilities/RiVA-README.txt` |
| **AHI 6.0** on the guest disk | Martin Blom; `paula.audio` and `toccata.audio` are public domain | GPL and LGPL (`AHI6/COPYING`, `COPYING.LIB`, `COPYING.DRIVERS`); Aminet's binaries, unchanged; source on Aminet: [`driver/audio/ahisrc`](https://aminet.net/package/driver/audio/ahisrc) |
| **WheelDriver, FreeWheel, SetAkiko** on the guest disk | Alastair M. Robinson, as Minimig for MiSTer ships them | see the tools' own notes |
| **MiSTer Main** (BigMig build) | MiSTer-devel, with our hybrid loader | GPLv3 |

⚠ **The firmware in this repository is a compiled binary.** Its source lives in its own
repository and is published separately, under its own licence.

If we have got an attribution wrong or left one out, please tell us — that is a bug like any
other.

---

The Amiga side of this core is Minimig's, and we track it. Changes that belong upstream should
go upstream.
