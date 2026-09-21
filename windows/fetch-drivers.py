#!/usr/bin/env python3
"""Fetch the driver packages listed in windows/drivers.txt.

Runs INSIDE the build container (windows/fetch-drivers.sh is the host side),
because extracting what the sources hand back needs 7z, and the promise is that
the host needs only docker.

Two kinds of manifest entry, and the hardware-ID one is the reason this exists:

  PCI\\VEN_8086&DEV_9A78     Microsoft Update Catalog, searched by hardware ID
  https://.../driver.zip    fetched directly

The catalog is the same place Windows Update gets drivers from, and it answers
a hardware-ID query with the driver for exactly that device - so the manifest
says which *devices* the stick has to cope with, not which files to download,
and the version is whatever Windows would have installed anyway. What comes
back is a plain .cab of INF files, with no installer wrapper to defeat.

Each package is fetched once. A name that already has an .inf under it is left
alone, so the driver an image was built with does not change underneath you on
the next build: to take a newer one, delete the directory and run again.
"""

import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse

CATALOG = "https://www.catalog.update.microsoft.com"
# The catalog serves a different page to something it does not recognise as a
# browser.
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")

BLUE, YELLOW, RED, OFF = "\033[1;34m", "\033[1;33m", "\033[1;31m", "\033[0m"
def log(m):  print(f"{BLUE}==>{OFF} {m}", flush=True)
def info(m): print(f"    {m}", flush=True)
def warn(m): print(f"{YELLOW}WARN:{OFF} {m}", file=sys.stderr, flush=True)
def die(m):  sys.exit(f"{RED}ERROR:{OFF} {m}")


def curl(args, capture=True):
    cmd = ["curl", "-sS", "-L", "--fail", "-A", UA, "--retry", "3",
           "--retry-delay", "2", "--connect-timeout", "20"] + args
    if not capture:
        cmd.remove("-sS")
        cmd.insert(1, "--progress-bar")
    r = subprocess.run(cmd, capture_output=capture, text=capture)
    if r.returncode:
        raise RuntimeError((r.stderr or "").strip() or f"curl exited {r.returncode}")
    return r.stdout if capture else ""


def search(query):
    """Catalog rows for a query, newest and most Windows-11-ish first."""
    page = curl([f"{CATALOG}/Search.aspx?q={urllib.parse.quote(query)}"])
    if "noResults" in page and "ResultsHeader" not in page:
        return []
    out = []
    for row in re.findall(r'<tr[^>]*id="[^"]*_R\d+[^"]*"[^>]*>(.*?)</tr>', page, re.S):
        guid = re.search(r'goToDetails\(&quot;([0-9a-f-]+)&quot;\)'
                         r'|goToDetails\("([0-9a-f-]+)"\)', row)
        if not guid:
            continue
        cells = [html.unescape(re.sub(r"<[^>]+>", " ", c)).strip()
                 for c in re.findall(r"<td[^>]*>(.*?)</td>", row, re.S)]
        cells = [re.sub(r"\s+", " ", c) for c in cells if c.strip()]
        if len(cells) < 5:
            continue
        out.append({
            "id": guid.group(1) or guid.group(2),
            "title": cells[0], "products": cells[1],
            "date": cells[3], "version": cells[4],
        })

    def key(u):
        d = u["date"].split("/")
        date = (int(d[2]), int(d[0]), int(d[1])) if len(d) == 3 else (0, 0, 0)
        ver = tuple(int(n) for n in re.findall(r"\d+", u["version"])[:4])
        # The same driver is published once per Windows family. They are
        # interchangeable as INF packages, but prefer the Windows 11 one so the
        # build is not quietly assembling an image out of Windows 10 packages.
        return (ver, date, "Windows 11" in u["products"])
    return sorted(out, key=key, reverse=True)


def download_url(update_id):
    """The catalog hands out the real CDN URL only through this POST."""
    body = json.dumps([{"size": 0, "languages": "", "uidInfo": update_id,
                        "updateID": update_id}])
    page = curl(["-X", "POST", f"{CATALOG}/DownloadDialog.aspx",
                 "--data-urlencode", f"updateIDs={body}"])
    urls = re.findall(r"https?://[^'\"]+\.(?:cab|msu|zip|exe)", page)
    if not urls:
        raise RuntimeError("the catalog returned no download URL")
    return urls[0]


def resolve(spec):
    """(url, provenance) for one manifest entry."""
    if spec.startswith(("http://", "https://")):
        return spec, {"source": "url"}
    hits = search(spec)
    if not hits:
        raise RuntimeError(f"the Update Catalog has nothing for '{spec}'")
    best = hits[0]
    info(f"catalog: {best['title']}")
    info(f"         {best['version']}, {best['date']}, {len(hits)} candidate(s)")
    return download_url(best["id"]), {
        "source": "catalog", "updateID": best["id"], "title": best["title"],
        "version": best["version"], "date": best["date"],
    }


def fetch(name, spec, dest):
    target = os.path.join(dest, name)
    if any(f.lower().endswith(".inf")
           for _, _, files in os.walk(target) for f in files):
        info(f"{name}: already fetched")
        return

    log(f"Fetching {name}")
    info(f"spec: {spec}")
    url, prov = resolve(spec)
    prov["url"] = url

    with tempfile.TemporaryDirectory(dir=dest) as tmp:
        archive = os.path.join(tmp, os.path.basename(urllib.parse.urlparse(url).path)
                               or "package.bin")
        info(f"downloading {os.path.basename(archive)}")
        curl(["-o", archive, url], capture=False)
        info(f"{os.path.getsize(archive) / 1e6:.0f} MB, extracting")

        staged = os.path.join(tmp, "x")
        r = subprocess.run(["7z", "x", "-y", "-bso0", "-bsp0", f"-o{staged}", archive],
                           capture_output=True, text=True)
        if r.returncode:
            raise RuntimeError(f"7z could not unpack {url}\n{r.stderr.strip()[:400]}")

        infs = [os.path.join(dp, f) for dp, _, fs in os.walk(staged)
                for f in fs if f.lower().endswith(".inf")]
        if not infs:
            # A vendor .exe that unpacks its payload at runtime is the usual
            # reason, and no amount of retrying fixes it.
            raise RuntimeError(
                f"no .inf anywhere in {url}\n"
                "       that download is an installer, not a driver package - use a\n"
                "       hardware ID so it comes from the Update Catalog instead")

        with open(os.path.join(staged, ".source"), "w") as f:
            json.dump(prov, f, indent=2)
        # Into place only once it is known good: a half-extracted directory
        # with one .inf in it would be skipped as "already fetched" forever.
        shutil.rmtree(target, ignore_errors=True)
        os.replace(staged, target)
    info(f"{name}: {len(infs)} INF(s)")


def main():
    manifest, dest = sys.argv[1], sys.argv[2]
    if not os.path.exists(manifest):
        info(f"no {manifest} - nothing to fetch")
        return
    entries = []
    for line in open(manifest):
        line = line.split("#", 1)[0].strip()
        if line:
            parts = line.split(None, 1)
            if len(parts) != 2:
                die(f"{manifest}: expected '<name> <hardware-id-or-url>', got: {line}")
            entries.append(parts)
    if not entries:
        info(f"{manifest} lists nothing - building without fetched drivers")
        return

    os.makedirs(dest, exist_ok=True)
    failed = []
    for name, spec in entries:
        try:
            fetch(name, spec, dest)
        except Exception as e:  # noqa: BLE001 - every failure is reported the same way
            warn(f"{name}: {e}")
            failed.append(name)
    if failed:
        die(f"could not fetch: {', '.join(failed)}\n"
            f"       fix or comment out the entry in {manifest}, or drop the package\n"
            "       into windows/drivers/<name>/ by hand - see windows/drivers/README.md")


if __name__ == "__main__":
    main()
