# Bind Consortium's `generic-uio` device-tree nodes to uio_pdrv_genirq.
#
# This only takes effect when the machine boots through an OE-generated
# extlinux.conf (UBOOT_EXTLINUX = "1"). NXP's default boot flow uses the
# U-Boot environment / boot.scr instead; in that case add
# `uio_pdrv_genirq.of_id=generic-uio` to `bootargs`, as the `boot/boot.cmd`
# staged by `csti build` does.

UBOOT_EXTLINUX_KERNEL_ARGS:append = " uio_pdrv_genirq.of_id=generic-uio"
