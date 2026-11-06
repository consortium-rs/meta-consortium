# Enable the kernel options Consortium's Linux side relies on: UIO
# (uio_pdrv_genirq / uio_dmem_genirq) for shared-memory and doorbell windows,
# and device-tree overlays.
#
# linux-imx inherits kernel-yocto, which merges every `.cfg` in SRC_URI into
# the final .config, so listing the fragment is enough.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://consortium.cfg"
