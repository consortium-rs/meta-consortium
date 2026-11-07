#!/usr/bin/env bash
# Provision an AWS EC2 Ubuntu instance for the Consortium Yocto builds.
#
#   ./setup.sh [--bsp imx|stm32mp|all] [--disk /dev/nvme1n1] [--no-sync] [--no-mount]
#
# Layout:
#   /workspace/downloads          DL_DIR      (restored from s3://consortium-build/downloads/)
#   /workspace/sstate-cache       SSTATE_DIR  (restored from s3://consortium-build/sstate-cache/)
#   /workspace/imx-yocto-bsp      NXP i.MX BSP   (repo + sources/meta-consortium)
#   /workspace/stm32mp-yocto-bsp  ST OpenSTLinux (repo + layers/meta-consortium)
#
# Build afterwards (see /workspace/BUILD.md, written by this script):
#   source /workspace/env-imx.sh <machine>     # -> build-fsl-imx-wayland-<machine>
#   source /workspace/env-stm32mp.sh           # -> build-openstlinuxweston-stm32mp2
set -euo pipefail

# ---------------------------------------------------------------- config ----
WORKSPACE=/workspace
S3_BUCKET=s3://consortium-build
DL_DIR="$WORKSPACE/downloads"
SSTATE_DIR="$WORKSPACE/sstate-cache"
IMX_DIR="$WORKSPACE/imx-yocto-bsp"
ST_DIR="$WORKSPACE/stm32mp-yocto-bsp"

META_CONSORTIUM_URL=https://github.com/consortium-rs/meta-consortium.git

IMX_MANIFEST_URL=https://github.com/nxp-imx/imx-manifest
IMX_MANIFEST_BRANCH=imx-linux-wrynose
IMX_MANIFEST_FILE=imx-6.18.37-2.1.0.xml
IMX_DISTRO=fsl-imx-wayland
IMX_MACHINES=(
  imx93-11x11-lpddr4x-evk
  imx93-11x11-lpddr4x-frdm
  imx93-14x14-lpddr4x-evk
  imx93-9x9-lpddr4-qsb
  imx937-15x15-lpddr5-frdm
  imx93w-14x12-lpddr4x-evk
  imx943-19x19-lpddr5-evk
  imx943-19x19-lpddr4-evk
  imx943-orangebox
  imx95-15x15-lpddr4x-frdm
  imx95-15x15-lpddr5-frdm
  imx95-19x19-lpddr5-evk
  imx95-19x19-lpddr5-frdm-pro
  imx952-15x15-lpddr5-frdm
  imx952-19x19-lpddr5-evk
)

ST_MANIFEST_URL=https://github.com/STMicroelectronics/oe-manifest.git
ST_MANIFEST_BRANCH=refs/tags/openstlinux-6.6-yocto-scarthgap-mpu-v26.06.10
ST_DISTRO=openstlinux-weston
ST_MACHINE=stm32mp2

GIT_NAME="Consortium Build"
GIT_EMAIL=build@csti.dev

# ------------------------------------------------------------------ args ----
BSP=all
DISK=
DO_SYNC=1
DO_MOUNT=1

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bsp) BSP=$2; shift 2 ;;
    --disk) DISK=$2; shift 2 ;;
    --no-sync) DO_SYNC=0; shift ;;
    --no-mount) DO_MOUNT=0; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done
case "$BSP" in imx|stm32mp|all) ;; *) echo "--bsp must be imx, stm32mp or all" >&2; exit 1 ;; esac

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] && die "run as the build user (e.g. ubuntu), not root; sudo is used where needed"
SUDO=sudo
ARCH=$(dpkg --print-architecture)
USER_NAME=$(id -un)
USER_GROUP=$(id -gn)

# ------------------------------------------------------------- OS check ----
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die "unsupported OS: ${PRETTY_NAME:-unknown} (need Ubuntu 22.04/24.04/26.04)"
case "${VERSION_ID:-}" in
  22.04|24.04|26.04) ;;
  *) die "unsupported Ubuntu release: $VERSION_ID (need 22.04, 24.04 or 26.04)" ;;
esac
log "Ubuntu $VERSION_ID ($ARCH)"

# ------------------------------------------------------------- packages ----
# Union of the ST (OpenSTLinux) and NXP (i.MX Yocto) host package lists.
PKGS=(
  bison bsdmainutils build-essential chrpath cpio debianutils diffstat efitools
  file flex gawk gcc git git-lfs iputils-ping libacl1 libcrypt-dev libgmp-dev
  libmpc-dev libssl-dev libusb-1.0-0 locales lz4 python3 python3-git
  python3-jinja2 python3-pexpect python3-pip python3-subunit socat texinfo
  unzip wget xterm xz-utils zstd
  # needed by this script itself
  curl ca-certificates
)

# Release-dependent packages.
case "$VERSION_ID" in
  22.04) PKGS+=(libegl1-mesa pylint libsdl1.2-dev) ;;
  *)     PKGS+=(pylint) ;;   # libegl1-mesa is gone; libsdl1.2-dev is resolved below
esac

# gcc-multilib only exists for x86; there is no 32-bit multilib on arm64.
[[ "$ARCH" == amd64 ]] && PKGS+=(gcc-multilib)

has_candidate() { apt-cache policy "$1" 2>/dev/null | grep -q 'Candidate: [^(]'; }

log "Installing host packages"
$SUDO apt-get update -y
if [[ "$VERSION_ID" != 22.04 ]]; then
  # 24.04+ ships SDL 1.2 as sdl12-compat; the old name is virtual on some releases.
  if has_candidate libsdl1.2-dev; then PKGS+=(libsdl1.2-dev)
  elif has_candidate libsdl1.2-compat-dev; then PKGS+=(libsdl1.2-compat-dev)
  else warn "no SDL 1.2 dev package on $VERSION_ID; skipping (only needed for qemu SDL UI)"
  fi
fi
INSTALL=()
for p in "${PKGS[@]}"; do
  if has_candidate "$p"; then INSTALL+=("$p"); else warn "package $p not available on $VERSION_ID/$ARCH; skipping"; fi
done
$SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${INSTALL[@]}"

# NXP requires a UTF-8 locale for bitbake.
$SUDO locale-gen en_US.UTF-8 >/dev/null
$SUDO update-locale LANG=en_US.UTF-8

# Ubuntu 24.04+ restricts unprivileged user namespaces through AppArmor, which
# breaks bitbake's network isolation ("User namespaces are not usable").
if [[ "$VERSION_ID" != 22.04 ]] && [[ -e /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]]; then
  log "Allowing unprivileged user namespaces for bitbake"
  echo 'kernel.apparmor_restrict_unprivileged_userns = 0' | $SUDO tee /etc/sysctl.d/60-bitbake-userns.conf >/dev/null
  $SUDO sysctl -q -p /etc/sysctl.d/60-bitbake-userns.conf
fi

# --------------------------------------------------------------- AWS CLI ----
if ! command -v aws >/dev/null 2>&1; then
  log "Installing AWS CLI v2"
  case "$ARCH" in
    amd64) AWS_ZIP=awscli-exe-linux-x86_64.zip ;;
    arm64) AWS_ZIP=awscli-exe-linux-aarch64.zip ;;
    *) die "no AWS CLI build for $ARCH" ;;
  esac
  tmp=$(mktemp -d)
  curl -fsSL "https://awscli.amazonaws.com/$AWS_ZIP" -o "$tmp/awscli.zip"
  unzip -q "$tmp/awscli.zip" -d "$tmp"
  $SUDO "$tmp/aws/install" --update
  rm -rf "$tmp"
fi

# ------------------------------------------------------------ workspace ----
pick_disk() {
  # Largest whole disk with no partitions, no filesystem and no mountpoint
  # (the attached EBS/instance-store volume, not the root disk).
  lsblk -dbnpo NAME,TYPE,SIZE | awk '$2=="disk"{print $3, $1}' | sort -rn | while read -r _ dev; do
    [[ -n $(lsblk -npo NAME "$dev" | tail -n +2) ]] && continue   # has partitions
    [[ -n $(lsblk -npo MOUNTPOINT "$dev" | tr -d '[:space:]') ]] && continue
    echo "$dev"; break
  done
}

if [[ $DO_MOUNT -eq 1 ]] && ! mountpoint -q "$WORKSPACE"; then
  [[ -z "$DISK" ]] && DISK=$(pick_disk)
  [[ -n "$DISK" ]] || die "no free data disk found; attach an EBS volume or pass --disk / --no-mount"
  [[ -b "$DISK" ]] || die "$DISK is not a block device"
  if ! $SUDO blkid -o value -s TYPE "$DISK" >/dev/null 2>&1; then
    log "Formatting $DISK as ext4"
    $SUDO mkfs.ext4 -q -L workspace "$DISK"
  fi
  UUID=$($SUDO blkid -o value -s UUID "$DISK")
  $SUDO mkdir -p "$WORKSPACE"
  if ! grep -q "UUID=$UUID" /etc/fstab; then
    echo "UUID=$UUID $WORKSPACE ext4 defaults,noatime,nofail,x-systemd.device-timeout=10 0 2" | $SUDO tee -a /etc/fstab >/dev/null
  fi
  $SUDO systemctl daemon-reload
  $SUDO mount "$WORKSPACE"
  log "Mounted $DISK at $WORKSPACE"
elif [[ $DO_MOUNT -eq 0 ]]; then
  $SUDO mkdir -p "$WORKSPACE"
fi
$SUDO chown "$USER_NAME:$USER_GROUP" "$WORKSPACE"
mkdir -p "$DL_DIR" "$SSTATE_DIR" "$IMX_DIR" "$ST_DIR"

# ----------------------------------------------------------- S3 caches ----
if [[ $DO_SYNC -eq 1 ]]; then
  aws sts get-caller-identity >/dev/null 2>&1 \
    || die "no AWS credentials; attach an instance role with s3:GetObject/ListBucket on consortium-build, or rerun with --no-sync"
  log "Restoring downloads from $S3_BUCKET/downloads/"
  aws s3 sync --only-show-errors "$S3_BUCKET/downloads/" "$DL_DIR/" --exclude 'tmp*' --exclude '*.lock'
  log "Restoring sstate-cache from $S3_BUCKET/sstate-cache/"
  aws s3 sync --only-show-errors "$S3_BUCKET/sstate-cache/" "$SSTATE_DIR/"
fi

# ------------------------------------------------------------------ git ----
git config --global user.name "$GIT_NAME"
git config --global user.email "$GIT_EMAIL"
git config --global color.ui false   # keep repo from asking
git lfs install --skip-repo >/dev/null

# ----------------------------------------------------------------- repo ----
mkdir -p "$HOME/bin"
if [[ ! -x "$HOME/bin/repo" ]]; then
  log "Installing repo"
  curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo > "$HOME/bin/repo"
  chmod a+x "$HOME/bin/repo"
fi
if ! grep -q 'HOME/bin' "$HOME/.bashrc" 2>/dev/null; then
  # shellcheck disable=SC2016
  echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
fi
export PATH="$HOME/bin:$PATH"

clone_layer() { # <dest>
  if [[ -d "$1/.git" ]]; then git -C "$1" pull --ff-only -q; else git clone -q "$META_CONSORTIUM_URL" "$1"; fi
}

if [[ $BSP == imx || $BSP == all ]]; then
  log "repo init/sync: NXP i.MX ($IMX_MANIFEST_FILE)"
  cd "$IMX_DIR"
  repo init -u "$IMX_MANIFEST_URL" -b "$IMX_MANIFEST_BRANCH" -m "$IMX_MANIFEST_FILE"
  repo sync -j"$(nproc)" --no-clone-bundle
  clone_layer "$IMX_DIR/sources/meta-consortium"
fi

if [[ $BSP == stm32mp || $BSP == all ]]; then
  log "repo init/sync: ST OpenSTLinux ($ST_MANIFEST_BRANCH)"
  cd "$ST_DIR"
  repo init -u "$ST_MANIFEST_URL" -b "$ST_MANIFEST_BRANCH"
  repo sync -j"$(nproc)" --no-clone-bundle
  clone_layer "$ST_DIR/layers/meta-consortium"
fi

# ------------------------------------------------------- build helpers ----
# Both helpers must be *sourced*: the vendor setup scripts cd into the build
# dir and export bitbake's environment into the calling shell.
cat > "$WORKSPACE/consortium-conf.sh" <<EOF
# Shared by env-imx.sh / env-stm32mp.sh. Idempotently points the current build
# dir at the shared caches and adds the meta-consortium layer.
_consortium_conf() { # <layer path>
  local conf=conf/local.conf
  grep -q '^# consortium-shared-caches' "\$conf" || cat >> "\$conf" <<'CONF'

# consortium-shared-caches
DL_DIR = "$DL_DIR"
SSTATE_DIR = "$SSTATE_DIR"
CONF
  grep -q "\$(basename "\$1")" conf/bblayers.conf || bitbake-layers add-layer "\$1"
}
EOF

cat > "$WORKSPACE/env-imx.sh" <<EOF
# source $WORKSPACE/env-imx.sh <machine>
# Machines: ${IMX_MACHINES[*]}
if [ -z "\${1:-}" ]; then
  echo "usage: source $WORKSPACE/env-imx.sh <machine>"; echo "machines: ${IMX_MACHINES[*]}"; return 1
fi
. $WORKSPACE/consortium-conf.sh
cd $IMX_DIR || return 1
_bdir=build-$IMX_DISTRO-\$1
if [ -f "\$_bdir/conf/local.conf" ]; then
  . ./setup-environment "\$_bdir"
else
  DISTRO=$IMX_DISTRO MACHINE=\$1 . ./imx-setup-release.sh -b "\$_bdir"
fi
_consortium_conf $IMX_DIR/sources/meta-consortium/meta-consortium-imx9
unset _bdir
echo "Ready: \$PWD  (e.g. bitbake imx-image-full)"
EOF

cat > "$WORKSPACE/env-stm32mp.sh" <<EOF
# source $WORKSPACE/env-stm32mp.sh
. $WORKSPACE/consortium-conf.sh
cd $ST_DIR || return 1
DISTRO=$ST_DISTRO MACHINE=$ST_MACHINE . layers/meta-st/scripts/envsetup.sh
_consortium_conf $ST_DIR/layers/meta-consortium/meta-consortium-stm32mp2
echo "Ready: \$PWD  (e.g. bitbake st-image-weston)"
EOF

{
  echo "# Consortium Yocto builds"
  echo
  echo "| BSP | Source dir | Build dir | Layer |"
  echo "| --- | --- | --- | --- |"
  for m in "${IMX_MACHINES[@]}"; do
    echo "| NXP \`$m\` | \`$IMX_DIR\` | \`$IMX_DIR/build-$IMX_DISTRO-$m\` | \`sources/meta-consortium/meta-consortium-imx9\` |"
  done
  echo "| ST \`$ST_MACHINE\` | \`$ST_DIR\` | \`$ST_DIR/build-${ST_DISTRO//-/}-$ST_MACHINE\` | \`layers/meta-consortium/meta-consortium-stm32mp2\` |"
  echo
  echo "Shared caches (set in each build's \`conf/local.conf\`): \`DL_DIR=$DL_DIR\`, \`SSTATE_DIR=$SSTATE_DIR\`."
  echo
  echo "## NXP"
  echo '```bash'
  echo "source $WORKSPACE/env-imx.sh <machine>"
  echo "# first time this runs:"
  echo "#   DISTRO=$IMX_DISTRO MACHINE=<machine> source imx-setup-release.sh -b build-$IMX_DISTRO-<machine>"
  echo "bitbake imx-image-full"
  echo '```'
  echo
  echo "## ST"
  echo '```bash'
  echo "source $WORKSPACE/env-stm32mp.sh"
  echo "# runs: DISTRO=$ST_DISTRO MACHINE=$ST_MACHINE source layers/meta-st/scripts/envsetup.sh"
  echo "bitbake st-image-weston"
  echo '```'
  echo
  echo "Both vendor setup scripts show a EULA on first run of each build dir; accept it interactively."
} > "$WORKSPACE/BUILD.md"

log "Done. See $WORKSPACE/BUILD.md"
log "Open a new shell (or: export PATH=\"\$HOME/bin:\$PATH\"), then: source $WORKSPACE/env-imx.sh <machine>  |  source $WORKSPACE/env-stm32mp.sh"
