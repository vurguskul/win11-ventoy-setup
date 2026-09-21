# Build environment for the Windows 11 VHDX pipeline.
#
# Everything the build needs lives in here, so the host needs only docker and
# /dev/kvm. Nothing in the image requires root at runtime: the container is
# meant to be run with --user $(id -u):$(id -g), and the pipeline works on
# plain files rather than on kernel block devices.
#
#   wimlib        wimapply/wimupdate - applies install.wim to an NTFS *file*
#   ntfs-3g       mkntfs/ntfscat/ntfscp/ntfsls on that file, with no mount
#   7zip          reads the ISO's UDF filesystem, which libarchive cannot
#   gptfdisk      sgdisk writes the GPT into a plain file
#   dosfstools    mkfs.vfat on a plain file
#   mtools        writes into the FAT images, and reads the ESP back out of
#                 the assembled disk with an offset= drive definition
#   qemu-*        the two boot phases, plus the final raw -> vhdx conversion
#   edk2-ovmf     UEFI firmware for those boots
FROM archlinux:base

# Retried: an Arch mirror dropping a package mid-transaction ("failed to
# retrieve some files") failed two of the first three builds of this image, and
# a rebuild is not something the user should have to know to repeat.
RUN set -eu; \
    ok=0; \
    for attempt in 1 2 3; do \
      if pacman -Syu --noconfirm --needed --disable-download-timeout \
           wimlib ntfs-3g dosfstools gptfdisk mtools 7zip \
           qemu-img qemu-system-x86 edk2-ovmf python; then ok=1; break; fi; \
      echo "pacman attempt $attempt failed; retrying"; sleep 5; \
    done; \
    [ "$ok" = 1 ]; \
    pacman -Scc --noconfirm

# An arbitrary --user has no home; several tools want one to exist.
ENV HOME=/tmp
WORKDIR /work
