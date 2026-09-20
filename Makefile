# boot-media - build bootable media for the Ventoy stick.
#
# Everything here is additive: no target formats or repartitions the stick.

SHELL := /bin/bash

.PHONY: help list-editions vhdboot windows test-boot screenshot clean

help:
	@echo "make list-editions   list the Windows editions in the ISO"
	@echo "make vhdboot         install ventoy_vhdboot.img on the stick (once)"
	@echo "make windows         build the Win11 VHDX and copy it to the stick"
	@echo "make test-boot       boot the stick in QEMU to verify (read-only)"
	@echo "make clean           remove out/"

list-editions:
	@windows/build-vhdx.sh --list-editions

vhdboot:
	@ventoy/fetch-vhdboot.sh

windows: vhdboot
	@windows/build-vhdx.sh

test-boot:
	@windows/test-boot.sh

screenshot:
	@windows/screenshot.sh

clean:
	rm -rf out/*
