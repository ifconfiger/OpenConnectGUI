#!/bin/sh
# Builds the vendored OpenConnect artifacts from pinned source releases:
#   Vendor/OpenConnect/macos/openconnect       arm64 macOS CLI (OpenSSL linked statically)
#   Vendor/OpenConnect/OpenConnect.xcframework  static libopenconnect + OpenSSL for arm64 iOS / simulator
#   Vendor/OpenConnect/vpnc-script              network configuration script for the macOS CLI
# Only Xcode command-line tools are required; libxml2, zlib and iconv come from the SDKs.
set -eu

OPENSSL_VERSION=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
OPENCONNECT_VERSION=9.21
OPENCONNECT_SHA256=5b32369467db6e5f317aa1ed12cfcbb81ed00bdbc765450b6bfcbdc300944a58
VPNC_SCRIPT_COMMIT=ce9e961bd0f6b867e1c7c35f78f6fb973f6ff101
MACOS_MIN=13.0
IOS_MIN=16.0

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=${WORK_DIR:-$root/build/openconnect}
out=$root/Vendor/OpenConnect
jobs=$(sysctl -n hw.ncpu)
mkdir -p "$work/src" "$out"

fetch() { # url file sha256
  [ -f "$work/src/$2" ] || curl -fsSL -o "$work/src/$2" "$1"
  echo "$3  $work/src/$2" | shasum -a 256 -c - >/dev/null
}

fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
  "openssl-$OPENSSL_VERSION.tar.gz" "$OPENSSL_SHA256"
fetch "https://www.infradead.org/openconnect/download/openconnect-$OPENCONNECT_VERSION.tar.gz" \
  "openconnect-$OPENCONNECT_VERSION.tar.gz" "$OPENCONNECT_SHA256"
curl -fsSL -o "$work/src/vpnc-script" \
  "https://gitlab.com/openconnect/vpnc-scripts/-/raw/$VPNC_SCRIPT_COMMIT/vpnc-script"

# Dependencies are passed via *_CFLAGS/*_LIBS; this stub satisfies configure's pkg-config
# version check and reports every other package as missing.
mkdir -p "$work/bin"
cat >"$work/bin/pkg-config" <<'STUB'
#!/bin/sh
case "$1" in
  --version) echo 0.29.2 ;;
  --atleast-pkgconfig-version) exit 0 ;;
  *) exit 1 ;;
esac
STUB
chmod 755 "$work/bin/pkg-config"

# build_slice <name> <sdk> <arch> <openssl-target> <min-version-flag>
build_slice() {
  name=$1 sdk=$2 arch=$3 ossl_target=$4 min_flag=$5
  dir=$work/$name
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  cc="$(xcrun --sdk "$sdk" -f clang) -arch $arch -isysroot $sysroot $min_flag"
  ossl=$dir/openssl-$OPENSSL_VERSION
  mkdir -p "$dir"

  if [ ! -f "$ossl/libcrypto.a" ]; then
    rm -rf "$ossl"
    tar xzf "$work/src/openssl-$OPENSSL_VERSION.tar.gz" -C "$dir"
    (cd "$ossl" &&
      CC="$cc" ./Configure "$ossl_target" no-shared no-module no-tests no-docs no-apps \
        no-engine no-ui-console --openssldir=/private/etc/ssl >"$dir/openssl.log" 2>&1 &&
      make -j"$jobs" build_libs >>"$dir/openssl.log" 2>&1)
  fi

  src=$dir/openconnect-$OPENCONNECT_VERSION
  rm -rf "$src"
  tar xzf "$work/src/openconnect-$OPENCONNECT_VERSION.tar.gz" -C "$dir"
  (cd "$src" &&
    CC="$cc" CFLAGS="-O2" PKG_CONFIG="$work/bin/pkg-config" \
    LIBXML2_CFLAGS="-I$sysroot/usr/include/libxml2" LIBXML2_LIBS="-lxml2" \
    ZLIB_CFLAGS="" ZLIB_LIBS="-lz" \
    OPENSSL_CFLAGS="-I$ossl/include" OPENSSL_LIBS="-L$ossl -lssl -lcrypto" \
    ac_cv_func_strchrnul=no \
    ./configure --host=aarch64-apple-darwin --build=x86_64-apple-darwin \
      --disable-shared --enable-static --disable-nls --disable-docs \
      --without-gnutls --without-openssl-version-check \
      --without-lz4 --without-libproxy --without-stoken --without-libpcsclite \
      --without-libpskc --without-gssapi --with-builtin-json \
      --with-vpnc-script=/etc/vpnc/vpnc-script \
      >"$dir/openconnect.log" 2>&1 &&
    make -j"$jobs" "${OC_MAKE_TARGET:-openconnect}" >>"$dir/openconnect.log" 2>&1)
}

merge_libs() { # dir output
  libtool -static -o "$2" "$1/openconnect-$OPENCONNECT_VERSION/.libs/libopenconnect.a" \
    "$1/openssl-$OPENSSL_VERSION/libssl.a" "$1/openssl-$OPENSSL_VERSION/libcrypto.a" 2>/dev/null
  strip -S "$2"
}

# macOS: the command-line tool, Apple silicon only.
build_slice macos-arm64 macosx arm64 darwin64-arm64-cc "-mmacosx-version-min=$MACOS_MIN"
mkdir -p "$out/macos"
install -m 755 "$work/macos-arm64/openconnect-$OPENCONNECT_VERSION/openconnect" "$out/macos/openconnect"
strip -S "$out/macos/openconnect"
install -m 755 "$work/src/vpnc-script" "$out/vpnc-script"
mkdir -p "$out/licenses"
cp "$work/macos-arm64/openconnect-$OPENCONNECT_VERSION/COPYING.LGPL" "$out/licenses/OpenConnect-COPYING.LGPL"
cp "$work/macos-arm64/openssl-$OPENSSL_VERSION/LICENSE.txt" "$out/licenses/OpenSSL-LICENSE.txt"

# iOS: only the library is needed; the extension provides the tunnel and network settings.
OC_MAKE_TARGET=libopenconnect.la
export OC_MAKE_TARGET
build_slice ios-arm64 iphoneos arm64 ios64-xcrun "-miphoneos-version-min=$IOS_MIN"
build_slice iossim-arm64 iphonesimulator arm64 iossimulator-arm64-xcrun "-mios-simulator-version-min=$IOS_MIN"

lib=$work/lib && rm -rf "$lib" && mkdir -p "$lib/ios" "$lib/sim" "$lib/headers"
merge_libs "$work/ios-arm64" "$lib/ios/libopenconnect.a"
merge_libs "$work/iossim-arm64" "$lib/sim/libopenconnect.a"
cp "$work/ios-arm64/openconnect-$OPENCONNECT_VERSION/openconnect.h" "$lib/headers/"
rm -rf "$out/OpenConnect.xcframework"
xcodebuild -create-xcframework \
  -library "$lib/ios/libopenconnect.a" -headers "$lib/headers" \
  -library "$lib/sim/libopenconnect.a" -headers "$lib/headers" \
  -output "$out/OpenConnect.xcframework" >/dev/null

echo "OpenConnect $OPENCONNECT_VERSION / OpenSSL $OPENSSL_VERSION artifacts written to $out"
