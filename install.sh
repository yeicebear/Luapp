#!/bin/sh
set -e
LPP_REPO="yeicebear/Luapp"
LPP_BIN="$HOME/.local/bin"
LPP_LIB="$HOME/.local/lib/lpp"
LPP_TMP="$(mktemp -d)"
trap 'rm -rf "$LPP_TMP"' EXIT
lpp_arch="$(uname -m)"
case "$lpp_arch" in
    x86_64)        lpp_arch="x86_64" ;;
    aarch64|arm64) lpp_arch="arm64"  ;;
    *) echo "unsupported arch: $lpp_arch" >&2; exit 1 ;;
esac
LPP_URL="https://github.com/${LPP_REPO}/releases/latest/download/lpp-linux-${lpp_arch}.tar.gz"
echo "🔥INSTALLING LPP TO ~/.local/bin YIPPEEE 🔥"
echo "lwk fetching the release..."
curl -fsSL "$LPP_URL" -o "$LPP_TMP/lpp.tar.gz"
tar -xzf "$LPP_TMP/lpp.tar.gz" -C "$LPP_TMP"
echo "lwk making a directory now"
mkdir -p "$LPP_BIN" "$LPP_LIB"
echo "if we being fr we lwk js copying stuff lmao"
install -m755 "$LPP_TMP/lpp"       "$LPP_BIN/lpp"
install -m755 "$LPP_TMP/qbe"       "$LPP_BIN/qbe"
install -m644 "$LPP_TMP/runtime.c" "$LPP_LIB/runtime.c"
install -m644 "$LPP_TMP/gamelib.c" "$LPP_LIB/gamelib.c"
echo "lpp: done. try: lpp --help"
