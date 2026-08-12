# extra/

`MiSTer_share.lha` — the Amiga side of the MiSTer shared folder: the `MiSTerFileSystem`
handler, a `dummy.device` and a `MountList`. Ships as-is in `releases/share/`.

## What used to be here, and where it went

The rest of this folder was Minimig-AGA's **Windows** build chain for that archive — VBCC
(`vc`), a BCPL entry/exit wrapper, two Python post-processing scripts, and `lhant.exe` to pack
it. Byte-identical to Minimig's, unmodified by us, and never run here: we ship the prebuilt
archive.

⇒ Removed 2026-08-12. **If you need to rebuild the handler, take it from
[Minimig-AGA_MiSTer](https://github.com/MiSTer-devel/Minimig-AGA_MiSTer) `extra/`**, which is
where it is maintained. `AtapiMagic.lha` went with it — it was not part of that chain and is
not part of this core.
