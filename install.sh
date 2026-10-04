#!/bin/sh
set -eu

# Map uname to a GitHub Release tarball name.
os=$(uname -s)
arch=$(uname -m)
case "$os" in
Linux) os=linux ;;
Darwin) os=macos ;;
*)
    printf '%s\n' "rv: no prebuilt binary for $(uname -s); build from source (Zig 0.17)" >&2
    exit 1
    ;;
esac
case "$arch" in
x86_64 | amd64) arch=x86_64 ;;
aarch64 | arm64) arch=aarch64 ;;
*)
    printf '%s\n' "rv: no prebuilt binary for $os/$arch; build from source (Zig 0.17)" >&2
    exit 1
    ;;
esac
asset="rv-${os}-${arch}.tar.gz"

prefix="${RV_PREFIX:-$HOME/.local}"

# RV_VERSION is v2.3. Older releases used v2.2.0. Unset means the latest release.
if [ -n "${RV_VERSION:-}" ]; then
    case "$RV_VERSION" in
        v*.*) version="${RV_VERSION#v}" ;;
        *)
            printf '%s\n' "rv: RV_VERSION must look like v2.3" >&2
            exit 1
            ;;
    esac
    # Two components (v2.3) or three (v2.2.0). Each component is digits.
    major="${version%%.*}"
    rest="${version#*.}"
    minor="${rest%%.*}"
    patch=""
    if [ "$rest" != "$minor" ]; then
        patch="${rest#*.}"
        if [ -z "$patch" ] || [ "$patch" != "${patch%%.*}" ]; then
            printf '%s\n' "rv: RV_VERSION must look like v2.3" >&2
            exit 1
        fi
    fi
    case "$major$minor$patch" in
        *[!0-9]*) bad=1 ;;
        *) bad= ;;
    esac
    if [ -n "$bad" ] || [ -z "$major" ] || [ -z "$minor" ]; then
        printf '%s\n' "rv: RV_VERSION must look like v2.3" >&2
        exit 1
    fi
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
"$prefix/bin/rv" --version
case ":$PATH:" in
*":$prefix/bin:"*) ;;
*)
    printf '%s\n' "export PATH=\"$prefix/bin:\$PATH\""
    ;;
esac
printf '%s\n' "next: npx skills add Zooce/rv -g"
