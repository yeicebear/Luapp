#!/bin/sh
set -e
LPP_REPO="yeicebear/Luapp"
LPP_BIN="$HOME/.local/bin"
LPP_LIB="$HOME/.local/lib/lpp"
LPP_TMP="$(mktemp -d)"
trap 'rm -rf "$LPP_TMP"' EXIT

progress() {
    msg="$1"
    i=0
    printf "%-35s [" "$msg"
    while [ $i -lt 20 ]; do
        printf "#"
        sleep 0.03
        i=$((i+1))
    done
    printf "] 100%%\n"
}

sleep 0.5
echo ":: LPP INSTALLER"
sleep 0.5
echo ":: resolving environment..."

lpp_arch="$(uname -m)"
case "$lpp_arch" in
    x86_64) lpp_arch="x86_64" ;;
    aarch64|arm64) lpp_arch="arm64" ;;
    *) echo "unsupported arch: $lpp_arch"; echo "bro what kind of cpu is that"; exit 1 ;;
esac

lpp_os="linux"
if [ "$(uname)" = "Darwin" ]; then
    echo ":: mac detected (bold choice)"
    lpp_os="darwin"
fi

sleep 0.5
echo ":: target: $lpp_os / $lpp_arch"

LPP_URL="https://github.com/${LPP_REPO}/releases/latest/download/lpp-${lpp_os}-${lpp_arch}.tar.gz"

progress "(1/5) downloading lpp"
curl -fsSL "$LPP_URL" -o "$LPP_TMP/lpp.tar.gz" || {
    echo "download failed. internet skill issue."
    exit 1
}

progress "(2/5) extracting package"
tar -xzf "$LPP_TMP/lpp.tar.gz" -C "$LPP_TMP" || {
    echo "tar failed. wrong file, genius."
    exit 1
}

progress "(3/5) preparing directories"
mkdir -p "$LPP_BIN" "$LPP_LIB"

progress "(4/5) installing files"
install -m755 "$LPP_TMP/lpp" "$LPP_BIN/lpp"
install -m755 "$LPP_TMP/qbe" "$LPP_BIN/qbe"
install -m644 "$LPP_TMP/runtime.c" "$LPP_LIB/runtime.c"
install -m644 "$LPP_TMP/stdlib.c" "$LPP_LIB/stdlib.c"
install -m644 "$LPP_TMP/gamelib.c" "$LPP_LIB/gamelib.c"

progress "(5/5) finalizing installation"

echo
echo ":: installation complete"
echo ":: lpp installed to $LPP_BIN"
echo ":: run: lpp --help"
echo ":: if command not found: check PATH"
echo ":: if still broken: blame the installer"
