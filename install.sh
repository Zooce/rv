#!/bin/sh
set -eu

# Map uname to a GitHub Release tarball name.
os=$(uname -s)
arch=$(uname -m)
case "$os" in
Linux) os=linux ;;
Darwin) os=macos ;;
*)
    printf '%s\n' "rv: no prebuilt binary for $(uname -s); build from source (Zig 0.16)" >&2
    exit 1
    ;;
esac
case "$arch" in
x86_64 | amd64) arch=x86_64 ;;
aarch64 | arm64) arch=aarch64 ;;
*)
    printf '%s\n' "rv: no prebuilt binary for $os/$arch; build from source (Zig 0.16)" >&2
    exit 1
    ;;
esac
asset="rv-${os}-${arch}.tar.gz"

prefix="${RV_PREFIX:-$HOME/.local}"
if [ -n "${RV_VERSION:-}" ]; then
    base="https://github.com/Zooce/rv/releases/download/${RV_VERSION}"
else
    base="https://github.com/Zooce/rv/releases/latest/download"
fi

download() {
    _url=$1
    _dest=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$_url" -o "$_dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$_dest" "$_url"
    else
        printf '%s\n' "rv: need curl or wget" >&2
        exit 1
    fi
}

# Fetch SHA256SUMS and the matching tarball.
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
printf '%s\n' "rv: downloading $asset"
download "$base/SHA256SUMS" "$tmpdir/SHA256SUMS"
download "$base/$asset" "$tmpdir/$asset"

# Check the tarball against the SHA256SUMS line for this asset.
(
    cd "$tmpdir"
    line=$(grep " ${asset}$" SHA256SUMS) || {
        printf '%s\n' "rv: no checksum for $asset" >&2
        exit 1
    }
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s\n' "$line" | sha256sum -c -
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s\n' "$line" | shasum -a 256 -c -
    else
        printf '%s\n' "rv: need sha256sum or shasum" >&2
        exit 1
    fi
)

# Unpack bin/rv into the prefix.
mkdir -p "$prefix"
tar -x -C "$prefix" -f "$tmpdir/$asset"
chmod 755 "$prefix/bin/rv"

printf '%s\n' "rv: installed $prefix/bin/rv"
case ":$PATH:" in
*":$prefix/bin:"*) ;;
*)
    printf '%s\n' "export PATH=\"$prefix/bin:\$PATH\""
    ;;
esac
printf '%s\n' "next: rv install-skill"
