# BigMig for MiSTer

A **Big Box Amiga** for the MiSTer board: the Minimig chipset in the FPGA fabric, driven by a
68k that is not in the fabric at all.

BigMig replaces the in-fabric soft CPU with **Emu68-A9**, an ARMv7 just-in-time recompiler
running bare-metal on the second ARM core of the DE10-Nano's HPS. The Amiga custom chips —
Agnus, Denise, Paula, Gary, the CIAs — are the same cycle-accurate Minimig logic they have
always been. Only the processor moved.

The result is an Amiga that is **169 MIPS** where Minimig's TG68K is about 12, and whose chip
RAM is nonetheless **faster than a real A600's**.

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
* **Core #0 runs MiSTer's Main with an explicit priority order**: **USB polling first**, at the
  same **1 ms** rate as official Main, then the **OSD**, then the **hard-drive device**. Input
  is never queued behind anything. Disk work — the only part that can afford to wait — waits.
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
| **CPU** | 68EC020 via the Emu68-A9 JIT — **169 MIPS**, on a dedicated ARM core. 68040 under development |
| **Chipset** | OCS / ECS / AGA — unmodified Minimig logic, in the fabric |
| **Chip RAM** | up to 2 MB, on a dedicated path (see below) |
| **Fast RAM** | 264 MB, served by the JIT from HPS DDR3 |
| **RTG** | **ZZ9000** Zorro III graphics, up to 1920×1080 |
| **Hard disk** | **bigmigHD.device** — autoboot, HDF images |
| **Floppy** | ADF, normal and turbo |
| **Kickstart** | 1.3, 2.0, 3.1, 3.2, 3.2.2 |
| **Video / audio / input** | the MiSTer framework, as every other core |

### Not here, and deliberately

* **No slow RAM.** The memory map this core is built around does not have it.
* **No soft CPU.** `fx68k` and `TG68K` are gone from the fabric, not parked — the seam is the
  only chip-bus master. That is what frees the logic and the timing margin.
* **No MiSTer RTG card.** ZZ9000 replaces it.
* **No Gayle IDE.** Storage goes through `bigmigHD.device`.
* **68EC020 only, today.** FPU and 68040 are being worked on in the firmware.

---

## Measured

* **169 MIPS**, and **308× an Amiga 600** — SysInfo 4.4.
* **Over 14×** Minimig's TG68K with Data Cache.

Chip-RAM accesses do not go over the Amiga chip bus. They go down the memory controller's own CPU port, where a cycle completes when SDRAM actually commits it rather than when arbitration says so. Agnus keeps absolute priority for DMA.

---

## Getting started

### Install

A release is a **dated set** — `BigMig_YYYYMMDD/` — and the core, the firmware and Main in it
belong together. Four files:

| from the release | goes to | what it is |
|---|---|---|
| `BigMig_YYYYMMDD.rbf` | `/media/fat/_Computer/`, or the card root | the core |
| `BigMig_YYYYMMDD.txt` | **beside the `.rbf`** | the sidecar — see below |
| `Emu68.img` | `/media/fat/linux/Emu68.img` | the JIT firmware that runs on ARM core #1 |
| `MiSTer` | `/media/fat/MiSTer` | MiSTer Main with the hybrid loader |

Then put a Kickstart ROM where you already keep Minimig's.

⚠ **The `.rbf` and the `.txt` must sit in the same folder and keep the same name.** Either
location works — `_Computer/` is where MiSTer lists cores — but the pair travels together, and
the loader finds the `.txt` by taking the core's own filename. Rename one without the other, or
split them, and the core starts with no CPU.

⚠ **Do not mix releases.** Firmware and gateware are versioned and tested together; taking one
file from an older set is the first thing to undo if something behaves strangely.

⚠ **`Emu68.img` keeps that exact name**, in `/media/fat/linux/`. It is the firmware, not a disk
image — the loader looks for it by that path and the core has no CPU without it.

⚠ **Back up your existing `/media/fat/MiSTer`** before replacing it.

### The sidecar, briefly

`BigMig.txt` sits next to `BigMig.rbf` and contains one line of Linux boot arguments —
`maxcpus=1`. It is the **official MiSTer per-core boot-args mechanism**, not something we
invented.

It exists because a core that hands an ARM core to a bare-metal JIT cannot have Linux
scheduling on that core. Loading BigMig reloads Linux with those arguments, so core #1 arrives
at the hybrid launch never having entered the new Linux instance at all. Loading any other core
reloads Linux without them, and that core gets its two CPUs back.

⚠ Both files must be present. `BigMig.rbf` without `BigMig.txt` will not start correctly.

### JIT Cache

One OSD row, saved per config slot, changeable live. It is a **compatibility** setting, not a
performance one: every step is slower than the one before, and they fix different things.

| setting | what it does |
|---|---|
| **64MB** | Normal speed. This is the default and it is what almost everything wants. |
| **0KB (compat)** | No translation cache at all. Slowest by far; the last resort when nothing else runs a title. |
| **64MB (verify)** | Emu68 checks each block itself instead of trusting a program to announce that it rewrote its own code. Many demos and WHDLoad titles never announce it, and the stale translation shows up as graphical glitches. |
| **64MB (chip speed)** | Re-translates only Chip RAM code, so that code is paced by the chip bus again, as on a real accelerator. This is what demos that time the CPU against the raster expect. The rest of the system stays fast. |
| **64MB (verify+chip)** | Both at once. One fixes correctness, the other fixes pacing — a demo that rewrites its own code *and* times itself against the raster needs both. Try it on anything the other two do not fix. |

If something behaves oddly, **try the default again before reporting it**, and tell us which
setting you used.

---

## Reporting something that does not work

This core is new and it will have gaps. Reports are genuinely useful — but only if we can
reproduce them. Please include:

1. **Kickstart** version used
2. **Workbench** version used
3. **JIT configuration** (or "defaults")
4. **WHDLoad** — *with its version* — or the **ADF** used
5. **What happened**, and a **snapshot** if there is anything to see

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
| **bigmigHD.device** and its autoboot ROM | Ruben Aparicio (@raparici) — the careless-autoboot approach is inspired by Michal Schulz's `brdc` | GPLv3 |
| **ZZ9000 driver** | MNT Research / Lukas F. Hartmann and contributors; the Monitor included here is ours | see the ZZ9000 project |
| **The seam** — `axi_seam_slave`, `seam_engine`, `seam_ipl`, `seam_cpuregs`, `h2f_axi3_to_lite`, the hybrid bridge | Ruben Aparicio (@raparici) | GPLv3 |
| **MiSTer Main** (BigMig build) | MiSTer-devel, with our hybrid loader | GPLv3 |

⚠ **The firmware in this repository is a compiled binary.** Its source lives in its own
repository and is published separately, under its own licence.

If we have got an attribution wrong or left one out, please tell us — that is a bug like any
other.

---

The Amiga side of this core is Minimig's, and we track it. Changes that belong upstream should
go upstream.
