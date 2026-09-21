# Drivers to inject

Anything with a `.inf` under this directory is added to the image's driver
store at build time, offline, by DISM in the WinPE phase. Nothing here is
installed into the running system by hand — Windows binds each package when it
meets hardware that matches it, and ignores the rest. That is what makes this
work for a stick that moves between machines: drop in every machine's drivers,
and each one binds where it belongs.

The contents are gitignored: they are large, they are not ours to ship, and
`make drivers` can fetch most of them again from the hardware IDs in
`windows/drivers.txt`.

## What belongs here

Network adapters, mainly. `install.wim` has no driver for any modern GPU, so
the image comes up on the Microsoft Basic Display Adapter — odd resolution,
no external monitor — but Windows Update fixes that on first boot for free,
provided the machine can reach it. It is the Wi-Fi card with no inbox driver
that strands you, so that is what the shipped `windows/drivers.txt` covers.
Graphics is deliberately not fetched here: 500-900 MB per machine, for
something Windows Update hands over anyway.

Add a GPU package by hand if you have a machine that will never have working
networking - that is what this directory is for.

## What a package looks like

A driver package is a **directory of files** — `something.inf`, a `.cat`, one
or more `.sys`/`.dll` — not an installer `.exe`. One subdirectory per package:

```
windows/drivers/
  intel-gfx-tgl/
    iigd_dch.inf
    ...
  realtek-audio/
    ...
```

## The usual route is not by hand

`windows/drivers.txt` lists devices by hardware ID and `make drivers` fetches
them into this directory from the Microsoft Update Catalog — already a bare
INF package, no installer to defeat. That is the path to reach for. What
follows is for the package the catalog does not carry.

## Getting one out of a vendor download

**Intel graphics** ship a `.zip` variant alongside the installer
(`gfx_win_101.*.zip` on intel.com) — unzip it and keep the whole tree.

**Windows Update Catalog** (`catalog.update.microsoft.com`) is the most
reliable source for everything else: search the device or vendor, download the
`.cab`, and it is already a bare INF package:

```bash
mkdir -p windows/drivers/intel-gfx-tgl
cd windows/drivers/intel-gfx-tgl && 7z x ~/Downloads/<driver>.cab
```

**Vendor `.exe` installers** (HP's `sp*.exe`, most OEM packages) are usually
self-extracting and give up their payload to `7z x` too. If `7z` produces
something with no `.inf` in it, the installer unpacks at runtime and is no use
here — find the same driver in the catalog instead.

## Which drivers you need

`lspci -nn` on the Linux side gives the vendor and device IDs; Windows spells
the same thing `PCI\VEN_8086&DEV_9A78`. The ones worth having are whatever
Windows has no inbox driver for at all — graphics first, then Wi-Fi if the
machine's card is not in the inbox set, then chipset and audio.

The build prints every INF it found, and fails rather than shipping an image
whose DISM pass did not succeed.
