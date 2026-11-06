# Build fixes for NXP's imx-gpu-sdk on current hosts.
#
# - do_compile: upstream sources prepare.sh, which is bash-only, from the
#   task's /bin/sh. Run the same FslBuild.py invocation under bash, with -e.
# - do_configure: the SDK's build scripts use ast.Num/Str/Bytes/NameConstant/
#   Ellipsis, which Python 3.14 removed; rewrite them to ast.Constant.

do_compile() {
    bash -c '
        set -e
        export FSL_PLATFORM_NAME=Yocto
        export ROOTFS=${STAGING_DIR_HOST}
        export FSL_HOST_ROOTFS=${STAGING_DIR_NATIVE}
        . ./prepare.sh
        FslBuild.py -vvvvv -t sdk -c install \
            --BuildThreads ${@oe.utils.parallel_make(d)} \
            --CMakeInstallPrefix ${S} \
            --UseFeatures [${FEATURES}] \
            --UseExtensions [${EXTENSIONS}] \
            --Variants [WindowSystem=${WINDOW_SYSTEM}]
    '
}

do_configure:prepend() {
    find ${S} -name '*.py' -exec sed -i -E \
        -e 's/\bast\.(Num|Str|Bytes|NameConstant|Ellipsis)\b/ast.Constant/g' {} +
}
