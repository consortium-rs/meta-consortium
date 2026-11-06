# Bind Consortium's `generic-uio` device-tree nodes to uio_pdrv_genirq.
#
# OpenSTLinux generates extlinux.conf in stm32mp-extlinux (via
# extlinuxconf-stm32mp.bbclass), so the kernel command line is extended here.
# A machine that sets a per-label UBOOT_EXTLINUX_KERNEL_ARGS_<label> overrides
# this value and needs the argument added there instead.

UBOOT_EXTLINUX_KERNEL_ARGS:append = " uio_pdrv_genirq.of_id=generic-uio"
