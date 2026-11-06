# Enable the kernel options Consortium's Linux side relies on: UIO
# (uio_pdrv_genirq / uio_dmem_genirq) for shared-memory and doorbell windows,
# and device-tree overlays.
#
# linux-stm32mp merges the fragments listed in KERNEL_CONFIG_FRAGMENTS with
# scripts/kconfig/merge_config.sh during do_configure.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://consortium.cfg"

KERNEL_CONFIG_FRAGMENTS:append = " ${WORKDIR}/consortium.cfg"
