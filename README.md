# romsort

Sort a messy ROM collection into a clean **LaunchBox** library without ever
breaking LaunchBox, and without touching a single original file.

```sh
git clone https://github.com/Spaceghost/romsort && cd romsort
cp config.lua my.lua        # point it at your drives
./romsort plan  --config my.lua   # dry run: hash, match, report. Writes nothing.
./romsort build --config my.lua   # build the sorted library, then check it
```

Needs only `bash`, coreutils, findutils, `unzip` and Lua 5.1+ (LuaJIT is
fastest). `7z` is optional; with it, `.7z` and `.rar` archives are matched too.

## What it does

romsort reads every source you list: a LaunchBox install, loose `Games`
folders on other drives, and dumps of handheld SD cards. It builds a second,
sorted LaunchBox root next to them:

```
sorted/LaunchBox/
  Games/<LaunchBox platform>/<No-Intro or Redump name>.<ext>
  Games/<platform>/Unverified/...      card ROMs no DAT recognises
  Data/  Images/  Emulators/ ...       mirrored from your install
```

* **Verified names.** Every file is SHA-1 hashed (zip members by CRC, with
  NES/Lynx/7800/SNES copier headers stripped) and matched against No-Intro and
  Redump DATs from libretro-database. Matches get their canonical name.
* **LaunchBox keeps working.** Every path in `Data/**/*.xml` is resolved,
  including `J:\` and `P:\` drive paths and wrong-case Windows names, and is
  rewritten to the file's new place. Only the path text changes; every other
  byte of the XML is preserved. Images match on titles, which never change.
* **Nothing is copied or moved.** The library is hardlinks into your sources,
  so it costs no disk. Deleting it loses nothing. Small mutable files
  (`Data/`, emulator configs, saves) are copied instead, so LaunchBox writing
  to them never reaches the original install.
* **Nothing breaks that worked.** `romsort check` (run after every build)
  fails if any LaunchBox path that resolved in your original no longer
  resolves, points at different content, or if the XML differs anywhere
  outside path values. Paths that were already broken are counted, left
  exactly as they were and listed in `launchbox-missing-at-source.tsv`.
* **Re-runnable.** Hashes are cached by size and mtime, so a rebuild only
  hashes what changed. A rebuild never overwrites a file you edited in the
  sorted library. If you edited a LaunchBox XML there, the new version is
  written beside it as `.romsort-new`.

### What is never renamed

* Arcade sets (MAME, FBNeo, Neo Geo, CPS, Naomi): emulators find a set by its
  zip name.
* Anything in a folder holding a multi-file disc image (`.cue`/`.bin`, `.gdi`,
  `.m3u`, `.ccd`), so cue sheets keep pointing at their tracks.
* Files inside per-game subfolders of a LaunchBox platform folder.
* Ports and OpenBOR trees, which are copied structure-for-structure.

## Commands

| command | does |
|---|---|
| `romsort plan` | scan, hash, match, write `plan.tsv` and `report.txt`; no library writes |
| `romsort build` | plan, then create or update the library, then `check` |
| `romsort check` | verify the library against the original LaunchBox install |
| `romsort start [plan\|build]` | run detached at low priority, logging to `run.log` |
| `romsort status` | running, interrupted or idle; current step, progress and ETA; report summary |
| `romsort log` | follow the detached run |
| `romsort ui` | live dashboard in Neovim (0.10+): run, totals, check and log windows |
| `:Romsort [status\|build\|plan\|check\|stop\|log\|report]` | the same from inside your own Neovim (see below) |
| `romsort autostart on\|off` | add or remove a cron entry that resumes an interrupted run, e.g. after a reboot |
| `romsort resume` | continue an interrupted run now (what cron calls; does nothing otherwise) |
| `romsort stop` | stop the detached run and forget it |

### Dashboard

The checkout is also a Neovim plugin. Put it on `runtimepath`, with any plugin
manager or `vim.opt.rtp:append('/path/to/romsort')`, and `:Romsort` opens the
dashboard in its own tab in the Neovim you already have open; `q` closes the
tab. `:Romsort build`, `:Romsort status` and the rest run the commands above
(tab-completed). Outside Neovim, `romsort ui` opens the same dashboard with four windows that refresh every
two seconds: **Run** (running, interrupted or idle, the current step, a
progress bar and the ETA), **Totals** (what was renamed, merged and left
unverified), **Check** (the last check result) and **Log** (the tail of
`run.log`, following). It only reads the state directory, so open and close it
whenever you like; the run carries on. Keys: `q` quit, `r` refresh, `b` start a
build, `p` start a plan, `x` stop the run, `L` full log, `R` full report.

### Long runs, reboots and progress

`romsort start build` records the goal in the state directory and runs
detached. The goal stays until the run succeeds. Every hash is written to the
cache the moment it is computed, and every library change is atomic and safe to
repeat. So after a reboot, crash or kill, `romsort resume` just runs it again
and only the unfinished work is done. With `romsort autostart on`, cron does
that every 10 minutes, and it waits quietly while the drives are not mounted.
A run that genuinely fails three times is parked in `goal.failed` instead of
retrying forever.

While it runs, `sorted/.romsort/progress` (shown by `romsort status`) says the
current step, how far through it the run is, and when that step should finish:

```
running: build
  step:    hash P (source 2 of 10)
  done:    212.4 / 552.0 GiB (38.5%)
  eta:     Wed 11:40 (2h05m left in this step)
  updated: Wed 2026-11-04 09:35:10 (run started Wed 08:01, 1h34m ago)
```

Everything a run produces lives in the state directory (`sorted/.romsort/`):
`files.tsv` and `members.tsv` (the hash cache), `plan.tsv`, `manifest.tsv`,
`report.txt`, `check.txt`, `launchbox-missing-at-source.tsv`, `progress`,
`goal` (while a detached run is unfinished) and `run.log`.

## Configuration

`config.lua` is plain Lua and documents every field. The parts you will touch:

* `out`, `state`: where the sorted LaunchBox root and its state go. These must be
  on the same filesystem as the sources, because hardlinks cannot cross
  filesystems.
* `launchbox`: the install whose `Data/` is mirrored and rewritten.
* `drives`: what each Windows drive letter in LaunchBox paths maps to.
* `sources`: each tree to sort, in precedence order. The layout is either
  `launchbox` (already `<Platform>/...`, folder names kept) or `folders` (card
  folders like `GBA`, `FC` or `megadrive` mapped through the platform aliases).
* `platforms`: LaunchBox platform names, folder aliases, DATs, and
  `rename = false` for systems that must keep their filenames.

Get the DATs with
`git clone --depth 1 https://github.com/libretro/libretro-database` and
point `ROMSORT_DATS` (or `dats`) at its `metadat/` directory.

## Tests

```sh
test/run.sh
```

builds a small fixture: a LaunchBox install with `J:\` and `P:\` paths, a
zipped ROM, a renamed ROM, a disc image, a card with duplicates, thumbnails and
an arcade set. It then checks every rule above, including that no source byte
changed, that a rebuild does nothing, and that edits in the library survive.

romsort only organises files you already own. It downloads nothing.
