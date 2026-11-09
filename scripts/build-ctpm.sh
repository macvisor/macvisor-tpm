#!/bin/zsh
# Builds Artifacts/CTPM.xcframework: libtpms (TPM 2.0 only) and OpenSSL's libcrypto, both static, for
# arm64 macOS, from their upstream release tarballs checked against pinned SHA-256s. Nothing comes from
# Homebrew or the system at link time; the build tools needed are autoconf, automake, libtool
# (glibtoolize), pkg-config and Xcode's command line tools.
#
#   scripts/build-ctpm.sh            build into build/, then replace Artifacts/CTPM.xcframework
#
# Commit the xcframework together with Artifacts/BUILD-INFO.txt, which this writes.
set -euo pipefail
ROOT=${0:A:h:h}
B=$ROOT/build
MIN_MACOS=15.0
JOBS=$(sysctl -n hw.ncpu)

OPENSSL_VERSION=3.5.9   # an LTS release line (supported to April 2030)
OPENSSL_URL=https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
LIBTPMS_VERSION=0.10.2
LIBTPMS_URL=https://github.com/stefanberger/libtpms/archive/refs/tags/v$LIBTPMS_VERSION.tar.gz
LIBTPMS_SHA256=edac03680f8a4a1c5c1d609a10e3f41e1a129e38ff5158f0c8deaedc719fb127

fetch() { # <url> <sha256> <file>
  local file=$B/src/$3
  mkdir -p $B/src
  [[ -f $file ]] || curl -fsSL -o $file.part $1 && { [[ -f $file ]] || mv $file.part $file; }
  local got=$(shasum -a 256 $file | cut -d' ' -f1)
  [[ $got == $2 ]] || { print -u2 "$3: SHA-256 $got, expected $2"; rm -f $file; exit 1; }
}

fetch $OPENSSL_URL $OPENSSL_SHA256 openssl-$OPENSSL_VERSION.tar.gz
fetch $LIBTPMS_URL $LIBTPMS_SHA256 libtpms-$LIBTPMS_VERSION.tar.gz

rm -rf $B/work $B/prefix
mkdir -p $B/work $B/prefix
PREFIX=$B/prefix
export MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS
CFLAGS_COMMON="-arch arm64 -mmacosx-version-min=$MIN_MACOS -O2 -fvisibility=hidden"

print "▸ OpenSSL $OPENSSL_VERSION (libcrypto, static)"
tar -xzf $B/src/openssl-$OPENSSL_VERSION.tar.gz -C $B/work
(
  cd $B/work/openssl-$OPENSSL_VERSION
  ./Configure darwin64-arm64-cc no-shared no-tests no-apps no-docs no-module no-dso no-engine no-legacy \
    --prefix=$PREFIX --libdir=lib "-mmacosx-version-min=$MIN_MACOS" > $B/openssl-configure.log 2>&1
  make -j$JOBS build_libs > $B/openssl-build.log 2>&1
  make install_dev > $B/openssl-install.log 2>&1
)

print "▸ libtpms $LIBTPMS_VERSION (TPM 2.0, static)"
tar -xzf $B/src/libtpms-$LIBTPMS_VERSION.tar.gz -C $B/work
(
  cd $B/work/libtpms-$LIBTPMS_VERSION
  export LIBTOOLIZE=glibtoolize
  # Only this OpenSSL, never another one pkg-config could find.
  export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
  export PKG_CONFIG_PATH=
  ./autogen.sh --with-openssl --with-tpm2 --without-tpm1 --disable-shared --enable-static --prefix=$PREFIX \
    CFLAGS="$CFLAGS_COMMON -I$PREFIX/include" LDFLAGS="-L$PREFIX/lib" > $B/libtpms-configure.log 2>&1
  make -j$JOBS > $B/libtpms-build.log 2>&1
  make install > $B/libtpms-install.log 2>&1
)

print "▸ CTPM.xcframework"
STAGE=$B/stage
rm -rf $STAGE && mkdir -p $STAGE/include/CTPM
libtool -static -o $STAGE/libCTPM.a $PREFIX/lib/libtpms.a $PREFIX/lib/libcrypto.a 2>/dev/null
cp $PREFIX/include/libtpms/*.h $STAGE/include/CTPM/
cat > $STAGE/include/CTPM/CTPM.h <<'H'
// libtpms' public API, for Swift (MacVisorTPM).
#include "tpm_types.h"
#include "tpm_error.h"
#include "tpm_library.h"
#include "tpm_memory.h"
#include "tpm_nvfilename.h"
#include "tpm_tis.h"
H
cat > $STAGE/include/CTPM/module.modulemap <<'M'
module CTPM {
    umbrella header "CTPM.h"
    export *
}
M
rm -rf $ROOT/Artifacts/CTPM.xcframework
mkdir -p $ROOT/Artifacts
xcodebuild -create-xcframework -library $STAGE/libCTPM.a -headers $STAGE/include -output $ROOT/Artifacts/CTPM.xcframework > $B/xcframework.log

# Each project's own licence, from its tarball, ships beside the library (THIRD-PARTY-NOTICES.md).
mkdir -p $ROOT/Artifacts/licenses
cp $B/work/libtpms-$LIBTPMS_VERSION/LICENSE $ROOT/Artifacts/licenses/libtpms-LICENSE.txt
cp $B/work/openssl-$OPENSSL_VERSION/LICENSE.txt $ROOT/Artifacts/licenses/openssl-LICENSE.txt

cat > $ROOT/Artifacts/BUILD-INFO.txt <<I
CTPM.xcframework, built by scripts/build-ctpm.sh
OpenSSL $OPENSSL_VERSION  $OPENSSL_URL  sha256 $OPENSSL_SHA256
libtpms $LIBTPMS_VERSION  $LIBTPMS_URL  sha256 $LIBTPMS_SHA256
arm64, macOS $MIN_MACOS or later; $(xcrun clang --version | head -1); $(sw_vers -productName) $(sw_vers -productVersion)
libCTPM.a sha256 $(shasum -a 256 $STAGE/libCTPM.a | cut -d' ' -f1)
I
print "▸ Done: $(du -sh $ROOT/Artifacts/CTPM.xcframework | cut -f1) in Artifacts/CTPM.xcframework"
