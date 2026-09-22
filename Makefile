# boot-media - build bootable media for the Ventoy stick.
#
# Everything here is additive: no target formats or repartitions the stick.
#
# The Windows build runs in a container (docker/Dockerfile), so the host needs
# only docker and /dev/kvm. `make test-boot` is the exception - it boots the
# physical stick, which needs qemu and sudo on the host.

SHELL := /bin/bash
IMAGE := boot-media-build

.PHONY: help image list-editions vhdboot drivers build windows copy repair test-boot screenshot shell clean

help:
	@echo "make list-editions   list the Windows editions in the ISO"
	@echo "make vhdboot         install ventoy_vhdboot.img on the stick (once)"
	@echo "make drivers         fetch the driver packages in windows/drivers.txt"
	@echo "make windows         build the Win11 VHDX and copy it to the stick"
	@echo "make build           build the VHDX only, leave the stick alone"
	@echo "make copy            copy an already-built VHDX to the stick"
	@echo "make repair          recover the stick's image after a failed update"
	@echo "make image           (re)build the build container"
	@echo "make shell           open a shell in the build container"
	@echo "make test-boot       boot the stick in QEMU to verify (read-only)"
	@echo "make clean           remove out/"

image:
	docker build -t $(IMAGE) -f docker/Dockerfile docker

list-editions:
	@windows/build.sh --list-editions

vhdboot:
	@ventoy/fetch-vhdboot.sh

# Fetched before the build because the image is deployed offline: Windows
# Update is not there to supply a display driver on first boot, so whatever is
# going into the driver store has to be on hand now. Already-fetched packages
# are left alone, so this is a no-op after the first run.
drivers:
	@windows/fetch-drivers.sh

build:
	@windows/build.sh

windows: vhdboot drivers build copy

copy:
	@windows/copy-to-stick.sh

# For an image that no longer boots because Windows Update left an update half
# installed - a vendor BIOS update is the one that does this here. Copies the
# image off the stick, boots its own WinRE against the copy to back the update
# out, and offers to put it back.
repair:
	@windows/repair.sh

test-boot:
	@windows/test-boot.sh

screenshot:
	@windows/screenshot.sh

# For poking at a half-built image: out/ is mounted at /work, the repo at /repo.
shell:
	docker run --rm -it --user $$(id -u):$$(id -g) \
	  --device /dev/kvm \
	  -v $(CURDIR):/repo:ro -v $(CURDIR)/out:/work \
	  $(IMAGE) bash

clean:
	rm -rf out/*
