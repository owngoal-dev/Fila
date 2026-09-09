#!/bin/zsh
# Builds the libcurl static library FilaFTP links, as an xcframework with
# iOS device, iOS simulator and macOS slices, from a pinned curl release.
#
# Pinned to curl 8.14.1: the last release with the Secure Transport backend,
# which is what gives FTPS certificate and hostname validation through the
# system trust store without bundling a CA file or a second TLS library.
# curl 8.15.0 removed that backend; moving past 8.14.1 means choosing and
# cross-building another TLS library and wiring its trust evaluation into the
# OS, which is deliberately not done here.
#
# Only FTP and FTPS are compiled in. Every other protocol, proxy support,
# cookies, MIME, HTTP and the auth schemes they need are disabled so the
# library is small and its surface is the one FilaFTP actually uses.
#
# Usage: Scripts/build-libcurl.sh [output xcframework]
# Default output: Packages/FilaKit/Binaries/libcurl.xcframework
set -euo pipefail

CURL_VERSION="8.14.1"
CURL_SHA256="f4619a1e2474c4bbfedc88a7c2191209c8334b48fa1f4e53fd584cc12e9120dd"
CURL_URL="https://curl.se/download/curl-${CURL_VERSION}.tar.xz"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$ROOT/Packages/FilaKit/Binaries/libcurl.xcframework}"
WORK="${LIBCURL_BUILD_DIR:-$ROOT/.build/libcurl}"
IOS_MIN="$(sed -n 's/^IPHONEOS_DEPLOYMENT_TARGET = \(.*\)$/\1/p' "$ROOT/Configuration/Base.xcconfig")"
MAC_MIN="$(sed -n 's/^MACOSX_DEPLOYMENT_TARGET = \(.*\)$/\1/p' "$ROOT/Configuration/Base.xcconfig")"
[[ -n "$IOS_MIN" && -n "$MAC_MIN" ]] || { echo "error: deployment targets missing from Base.xcconfig" >&2; exit 65; }

mkdir -p "$WORK"
TARBALL="$WORK/curl-${CURL_VERSION}.tar.xz"
if [[ ! -f "$TARBALL" ]]; then
    echo "==> downloading curl ${CURL_VERSION}"
    curl -sSLo "$TARBALL" "$CURL_URL"
fi
ACTUAL="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
[[ "$ACTUAL" == "$CURL_SHA256" ]] || { echo "error: curl tarball checksum mismatch: $ACTUAL" >&2; exit 65; }

SOURCE="$WORK/curl-${CURL_VERSION}"
if [[ ! -d "$SOURCE" ]]; then
    tar -xJf "$TARBALL" -C "$WORK"
fi

CC="$(xcrun -f clang)"
COMMON_FLAGS=(
    --disable-shared --enable-static
    --with-secure-transport
    --enable-ftp --enable-ipv6 --enable-threaded-resolver
    --disable-http --disable-file --disable-ldap --disable-ldaps --disable-rtsp
    --disable-proxy --disable-dict --disable-telnet --disable-tftp --disable-pop3
    --disable-imap --disable-smb --disable-smtp --disable-gopher --disable-mqtt
    --disable-manual --disable-docs --disable-libcurl-option --disable-unix-sockets
    --disable-cookies --disable-mime --disable-form-api --disable-ntlm
    --disable-tls-srp --disable-websockets --disable-headers-api --disable-hsts
    --disable-alt-svc --disable-doh --disable-ipfs --disable-verbose
    --without-zlib --without-brotli --without-zstd --without-libpsl
    --without-libidn2 --without-nghttp2 --without-librtmp --without-libssh2
    --without-ca-bundle --without-ca-path
)

# `ac_cv_func_pipe2=no`: the simulator SDK's libSystem exports pipe2 but its
# headers do not declare it, so configure's link probe says yes and the
# compile then fails. Darwin has no pipe2; curl's socketpair fallback is used.
build_slice() {
    local name="$1" host="$2" sdk="$3" target="$4"
    local prefix="$WORK/out/$name"
    local build="$WORK/build/$name"
    local sysroot
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    echo "==> building libcurl for $name"
    rm -rf "$build" "$prefix"
    mkdir -p "$build"
    (
        cd "$build"
        "$SOURCE/configure" --host="$host" --prefix="$prefix" \
            CC="$CC" \
            CFLAGS="-target $target -isysroot $sysroot -O2" \
            CPPFLAGS="-isysroot $sysroot" \
            LDFLAGS="-target $target -isysroot $sysroot" \
            ac_cv_func_pipe2=no \
            "${COMMON_FLAGS[@]}" > configure.log 2>&1 \
            || { tail -40 configure.log >&2; exit 1; }
        make -j"$(sysctl -n hw.ncpu)" > make.log 2>&1 || { tail -40 make.log >&2; exit 1; }
        make install > install.log 2>&1
    )
    # `curl-config` and the pkg-config file are host tooling, not library payload.
    rm -rf "$prefix/bin" "$prefix/share" "$prefix/lib/pkgconfig"
}

build_slice ios-arm64 arm-apple-darwin iphoneos "arm64-apple-ios${IOS_MIN}"
build_slice ios-arm64-simulator arm-apple-darwin iphonesimulator "arm64-apple-ios${IOS_MIN}-simulator"
build_slice macos-arm64 arm-apple-darwin macosx "arm64-apple-macos${MAC_MIN}"

echo "==> assembling $OUTPUT"
rm -rf "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
xcodebuild -create-xcframework \
    -library "$WORK/out/ios-arm64/lib/libcurl.a" -headers "$WORK/out/ios-arm64/include" \
    -library "$WORK/out/ios-arm64-simulator/lib/libcurl.a" -headers "$WORK/out/ios-arm64-simulator/include" \
    -library "$WORK/out/macos-arm64/lib/libcurl.a" -headers "$WORK/out/macos-arm64/include" \
    -output "$OUTPUT" > "$WORK/xcframework.log" 2>&1 || { cat "$WORK/xcframework.log" >&2; exit 1; }

# The pinned version is recorded beside the binary so the harness can prove
# the built library is the one this script describes.
cat > "$OUTPUT/FILA-VERSION" <<EOF
curl ${CURL_VERSION}
sha256 ${CURL_SHA256}
tls secure-transport
protocols ftp ftps
EOF

for slice in ios-arm64 macos-arm64; do
    lib="$OUTPUT/$slice/libcurl.a"
    echo "==> $slice: $(lipo -info "$lib" | sed 's/.*: //')"
done
echo "==> done"
