#!/usr/bin/env bash
# Install togglesurf on Ubuntu, including Zig and the system packages it needs.
#
# From a checkout, as root:
#   bash install.sh
#
# The same way Coolify is installed, once this file is hosted:
#   curl -fsSL https://example.com/toggle-surf/install.sh | sudo bash
#
# When the script is piped to bash it is not sitting next to the source, so
# point it at a git checkout:
#   curl -fsSL https://example.com/toggle-surf/install.sh | sudo \
#     TOGGLESURF_REPO=https://github.com/OWNER/toggle-surf.git bash
#
# Optional environment:
#   TOGGLESURF_SRC    directory that already contains build.zig
#   TOGGLESURF_REPO   git URL used when no local source is found
#   TOGGLESURF_REF    branch, tag, or commit to clone
#   TOGGLESURF_PREFIX install prefix (default: /usr/local)

set -euo pipefail

ZIG_VERSION="0.16.0"
PREFIX="${TOGGLESURF_PREFIX:-/usr/local}"
ZIG_ROOT="${PREFIX}/lib/zig-${ZIG_VERSION}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  GREEN=$'\033[1;32m'
  RED=$'\033[1;31m'
  RESET=$'\033[0m'
else
  GREEN=""
  RED=""
  RESET=""
fi

log() { printf '%s==>%s %s\n' "$GREEN" "$RESET" "$*" >&2; }
die() { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ] && command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
  fi
  die "run as root: sudo bash install.sh   or   curl -fsSL <install.sh> | sudo bash"
fi

if [ ! -r /etc/os-release ]; then
  die "this installer supports Ubuntu"
fi
# shellcheck disable=SC1091
. /etc/os-release
if [ "${ID:-}" != "ubuntu" ]; then
  die "this installer supports Ubuntu (found ${PRETTY_NAME:-unknown})"
fi

case "$(uname -m)" in
  x86_64)
    ZIG_ARCH="x86_64"
    ZIG_SHA="70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00"
    ;;
  aarch64 | arm64)
    ZIG_ARCH="aarch64"
    ZIG_SHA="ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17"
    ;;
  armv7l | armv6l)
    ZIG_ARCH="arm"
    ZIG_SHA="f85116bf2f9189bb6ae280c7f92f03b89c2551a88e17881c0c2df86bf4e42c50"
    ;;
  riscv64)
    ZIG_ARCH="riscv64"
    ZIG_SHA="bc069b0f2f568f54bafbdfc1d65b12fd386ed6a652044a37aee6a4f72f14076e"
    ;;
  *)
    die "unsupported architecture: $(uname -m)"
    ;;
esac

log "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  xz-utils \
  tar \
  git \
  build-essential

install_zig() {
  if [ -x "${ZIG_ROOT}/zig" ] && [ "$("${ZIG_ROOT}/zig" version)" = "$ZIG_VERSION" ]; then
    log "Zig ${ZIG_VERSION} already installed"
    return
  fi

  local name url tmp extracted
  name="zig-${ZIG_ARCH}-linux-${ZIG_VERSION}"
  url="https://ziglang.org/download/${ZIG_VERSION}/${name}.tar.xz"
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  log "Downloading Zig ${ZIG_VERSION} (${ZIG_ARCH})"
  curl -fsSL --retry 3 --retry-delay 2 -o "${tmp}/zig.tar.xz" "$url"
  echo "${ZIG_SHA}  ${tmp}/zig.tar.xz" | sha256sum -c -
  tar -xJf "${tmp}/zig.tar.xz" -C "$tmp"
  extracted="${tmp}/${name}"
  [ -x "${extracted}/zig" ] || die "Zig archive did not contain ${name}/zig"

  rm -rf "$ZIG_ROOT"
  mkdir -p "$(dirname "$ZIG_ROOT")"
  mv "$extracted" "$ZIG_ROOT"
  trap - RETURN
  rm -rf "$tmp"
}

install_zig
mkdir -p "${PREFIX}/bin"
ln -sfn "${ZIG_ROOT}/zig" "${PREFIX}/bin/zig"
log "Zig $("${PREFIX}/bin/zig" version) is on PATH"

find_source() {
  local candidate
  if [ -n "${TOGGLESURF_SRC:-}" ]; then
    [ -f "${TOGGLESURF_SRC}/build.zig" ] || die "TOGGLESURF_SRC has no build.zig: ${TOGGLESURF_SRC}"
    (cd "$TOGGLESURF_SRC" && pwd)
    return
  fi
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "${candidate}/build.zig" ]; then
      printf '%s\n' "$candidate"
      return
    fi
  fi
  if [ -n "${TOGGLESURF_REPO:-}" ]; then
    local dest
    dest="$(mktemp -d)/togglesurf"
    CLEANUPS+=("$(dirname "$dest")")
    log "Cloning ${TOGGLESURF_REPO}"
    if [ -n "${TOGGLESURF_REF:-}" ]; then
      git clone --depth 1 --branch "$TOGGLESURF_REF" "$TOGGLESURF_REPO" "$dest"
    else
      git clone --depth 1 "$TOGGLESURF_REPO" "$dest"
    fi
    printf '%s\n' "$dest"
    return
  fi
  die "no togglesurf source found. Run this script from a checkout, set TOGGLESURF_SRC, or set TOGGLESURF_REPO."
}

CLEANUPS=()
cleanup() {
  local dir
  for dir in "${CLEANUPS[@]}"; do
    rm -rf "$dir"
  done
}
trap cleanup EXIT

SOURCE="$(find_source)"
log "Building togglesurf from ${SOURCE}"
stage="$(mktemp -d)"
CLEANUPS+=("$stage")
cp "${SOURCE}/build.zig" "${SOURCE}/build.zig.zon" "$stage/"
cp -a "${SOURCE}/src" "${stage}/src"
(
  cd "$stage"
  "${PREFIX}/bin/zig" build -Doptimize=ReleaseSafe --prefix "$PREFIX"
)

[ -x "${PREFIX}/bin/togglesurf" ] || die "build finished without ${PREFIX}/bin/togglesurf"

log "Installed ${PREFIX}/bin/togglesurf"
cat <<EOF

Open a shell in one terminal:

  togglesurf host

In the other terminal, join with the connect code it prints:

  togglesurf join CODE

The code is the password. Add --lan on the host to listen beyond 127.0.0.1.
EOF
