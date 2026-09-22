#!/usr/bin/env bash
# Shared helpers for win11-ventoy-setup build scripts.

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit "${2:-1}"; }

need() {
  local missing=()
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
  (( ${#missing[@]} == 0 )) || die "missing tools: ${missing[*]}
       the build tools live in the container (docker/Dockerfile), not on the
       host; on the host you need only docker."
}

# Case-insensitive lookup: an ISO's UDF names are not reliably lower case, and
# 7z reproduces whatever case it finds.
find_ci() { find "$1" -ipath "$1/$2" -print -quit 2>/dev/null; }

# Free bytes on the filesystem holding $1.
free_bytes() { df -B1 --output=avail "$1" | tail -1 | tr -d ' '; }

human() { numfmt --to=iec-i --suffix=B "$1"; }

# Encode a password the way unattend.xml wants it: base64 of UTF-16LE of
# (password + element name). Keeps the plaintext out of the rendered file.
# $1 = password, $2 = element name (Password | AdministratorPassword)
unattend_password() {
  printf '%s' "$1$2" | iconv -f UTF-8 -t UTF-16LE | base64 -w0
}

# Resolve the mountpoint of the Ventoy exFAT data partition, or empty.
find_ventoy() {
  local dev mp
  while read -r dev mp; do
    [[ -n $mp ]] || continue
    printf '%s\n' "$mp"
    return 0
  done < <(lsblk -rno NAME,MOUNTPOINT,LABEL | awk '$3=="Ventoy"{print "/dev/"$1, $2}')
  return 1
}

# Print the images in a WIM as "index<TAB>name".
#
# The single parser for wiminfo output: listing and name->index lookup must not
# drift apart. wiminfo prints "Name:<spaces><value>", and the value contains
# spaces itself, so strip the label textually rather than by awk field.
wim_editions() {
  wiminfo "$1" | awk '
    /^Index:[[:space:]]/ { idx = $NF }
    /^Name:[[:space:]]/ {
      line = $0
      sub(/^Name:[[:space:]]*/, "", line)
      sub(/[[:space:]]+$/, "", line)
      printf "%s\t%s\n", idx, line
    }'
}
