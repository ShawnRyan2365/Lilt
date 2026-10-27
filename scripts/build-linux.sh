#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
VERSION=${VERSION:-0.3.2}
# SCRATCH lets a container build beside a macOS checkout without sharing its .build directory.
SCRATCH=${SCRATCH:-.build}
for pair in aarch64:arm64 x86_64:x86-64; do
    triple=${pair%%:*}
    arch=${pair##*:}
    sdk="$triple-swift-linux-musl"
    swift build -c release --swift-sdk "$sdk" --product lilt --scratch-path "$SCRATCH"
    output="build/linux/Lilt-$VERSION-linux-$arch"
    mkdir -p build/linux
    cp "$SCRATCH/$sdk/release/lilt" "$output"
    chmod 755 "$output"
    # LLVM's strip understands both architectures; GNU strip has produced a broken x86-64 binary before.
    if command -v llvm-strip >/dev/null 2>&1; then
        llvm-strip "$output"
    elif command -v llvm-strip-18 >/dev/null 2>&1; then
        llvm-strip-18 "$output"
    elif command -v llvm-objcopy >/dev/null 2>&1; then
        llvm-objcopy --strip-all "$output"
    elif command -v "$triple-linux-gnu-strip" >/dev/null 2>&1; then
        "$triple-linux-gnu-strip" "$output"
    elif [ "$(uname -m)" = "$triple" ]; then
        strip "$output"
    fi
    cp "$output" build/linux/lilt
    tar -C build/linux -czf "$output.tar.gz" lilt
    rm build/linux/lilt
done
# Only this version's packages: older ones left in build/linux are not part of this build.
if command -v sha256sum >/dev/null 2>&1; then
    (cd build/linux && sha256sum "Lilt-$VERSION-linux-"*.tar.gz > SHA256SUMS)
else
    (cd build/linux && shasum -a 256 "Lilt-$VERSION-linux-"*.tar.gz > SHA256SUMS)
fi
printf 'Built static Linux packages in build/linux. Test both binaries on their target architectures before release.\n'
