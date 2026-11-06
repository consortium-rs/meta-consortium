# meta-consortium

Yocto/OpenEmbedded layers that prepare a vendor BSP for
[Consortium](https://github.com/consortium-rs/consortium) applications: the kernel
options its Linux side needs (UIO, device-tree overlays), the kernel command
line that binds its `generic-uio` nodes, and build fixes for vendor recipes.

The repository holds one layer per SoC family. Add only the one that matches
your BSP.

| Layer                      | BSP                                           | Depends on                    | Yocto series |
| -------------------------- | --------------------------------------------- | ----------------------------- | ------------ |
| `meta-consortium-imx9`     | NXP i.MX 93 / 95 (meta-freescale, meta-imx)   | `core`, `freescale-layer`     | wrynose      |
| `meta-consortium-stm32mp2` | ST STM32MP2 OpenSTLinux (meta-st-stm32mp)     | `core`, `stm-st-stm32mp`      | scarthgap    |

## What each layer changes

Both layers:

- **Kernel**: merge `consortium.cfg` (`CONFIG_UIO`, `CONFIG_UIO_PDRV_GENIRQ`,
  `CONFIG_UIO_DMEM_GENIRQ`, `CONFIG_OF_OVERLAY`, `CONFIG_OF_CONFIGFS`) into the
  vendor kernel (`linux-imx` / `linux-stm32mp`).
- **Boot**: append `uio_pdrv_genirq.of_id=generic-uio` to the extlinux kernel
  arguments, so the UIO driver binds the nodes `csti build` generates.

`meta-consortium-imx9` only:

- The extlinux argument applies only to machines with `UBOOT_EXTLINUX = "1"`.
  NXP's default flow boots from the U-Boot environment / `boot.scr`; use the
  `boot/boot.cmd` staged by `csti build`, or add the argument to `bootargs`.
- `imx-gpu-sdk` build fixes (bash for `prepare.sh`, Python 3.14 `ast` names).
  These live under `dynamic-layers/fsl-sdk-release/` and are parsed only when
  NXP's `meta-imx-sdk` is in the build.

`meta-consortium-stm32mp2` only:

- The kernel argument is set in `stm32mp-extlinux`, the recipe that writes
  OpenSTLinux's `extlinux.conf`.

The layers do not install the Consortium application itself. `csti build`
writes a self-contained recipe (`<name>.bb`) next to its `dist/` tree; put both
in your own application layer and add the package to your image.

## Adding a layer

Clone this repository next to your other layers and add the matching one:

```sh
git clone https://github.com/consortium-rs/meta-consortium.git ../sources/meta-consortium

# NXP i.MX 9
bitbake-layers add-layer ../sources/meta-consortium/meta-consortium-imx9

# ST STM32MP2
bitbake-layers add-layer ../sources/meta-consortium/meta-consortium-stm32mp2
```

Or in a `kas` file:

```yaml
repos:
  meta-consortium:
    url: https://github.com/consortium-rs/meta-consortium.git
    branch: main
    layers:
      meta-consortium-stm32mp2:
```

Check that the layer is parsed and its appends apply:

```sh
bitbake-layers show-layers
bitbake-layers show-appends | grep -A1 -e linux- -e extlinux -e u-boot
```

## Contributing

Report issues and send pull requests to
<https://github.com/consortium-rs/meta-consortium>.

Maintainer: Ethan Wu

## License

Apache-2.0; see [LICENSE](LICENSE).
