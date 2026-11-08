#!/usr/bin/env bash
# Build ngspice (shared-library API) as a WebAssembly module, and optionally
# a native ngspice from the same sources for comparison.
#
# Usage: scripts/build_ngspice_wasm.sh [--native]
#
# Output:
#   target/ngspice-wasm/ngspice.mjs, ngspice.wasm   ES module + WASM
#   target/ngspice-native/ngspice                     with --native
#
# Versions come from pins.toml: the ngspice release tarball (checked by
# SHA-256), the patches in patches/ngspice-<version>/, and the Emscripten
# version (installed into target/emsdk if no matching emcc is on PATH).
# Runs locally; nothing here needs CI minutes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE=0
[ "${1:-}" = "--native" ] && NATIVE=1

pin() { # section key
  awk -v s="[$1]" -v k="$2" '
    $0 == s { inside = 1; next }
    /^\[/ { inside = 0 }
    inside && $1 == k { sub(/^[^=]*= *"/, ""); sub(/".*/, ""); print; exit }
  ' "$ROOT/pins.toml"
}
NGSPICE_VERSION="$(pin ngspice version)"
NGSPICE_URL="$(pin ngspice url)"
NGSPICE_SHA256="$(pin ngspice sha256)"
EMSCRIPTEN_VERSION="$(pin emscripten version)"
: "${NGSPICE_VERSION:?pins.toml: [ngspice] version}" "${EMSCRIPTEN_VERSION:?pins.toml: [emscripten] version}"

CACHE="$ROOT/target/cache"
SRC="$ROOT/target/ngspice-src/ngspice-$NGSPICE_VERSION"
mkdir -p "$CACHE"

# 1. sources
TARBALL="$CACHE/ngspice-$NGSPICE_VERSION.tar.gz"
if [ ! -f "$TARBALL" ] || [ "$(sha256sum "$TARBALL" | cut -d' ' -f1)" != "$NGSPICE_SHA256" ]; then
  curl -fsSL -o "$TARBALL" "$NGSPICE_URL"
fi
got="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
[ "$got" = "$NGSPICE_SHA256" ] || { echo "ngspice tarball: SHA-256 $got, expected $NGSPICE_SHA256" >&2; exit 1; }
rm -rf "$SRC"
mkdir -p "$(dirname "$SRC")"
tar xzf "$TARBALL" -C "$(dirname "$SRC")"
for p in "$ROOT/patches/ngspice-$NGSPICE_VERSION"/*.patch; do
  [ -e "$p" ] || continue
  patch -s -d "$SRC" -p1 < "$p"
done

# Features: the analog simulator, with periodic steady state (.pss, an
# experimental option that is off by default). XSPICE (mixed-signal code
# models) loads plugins with dlopen and needs separate work for WASM; CIDER
# and OSDI are not needed for sky130.
FEATURES=(--disable-debug --disable-openmp --without-x
        --with-readline=no --disable-xspice --disable-cider --enable-osdi=no
        --enable-pss)
CONFIG=(--with-ngshared "${FEATURES[@]}")

# 2. Emscripten
if ! command -v emcc >/dev/null || ! emcc --version | head -1 | grep -q " $EMSCRIPTEN_VERSION "; then
  EMSDK="$ROOT/target/emsdk"
  [ -d "$EMSDK" ] || git clone -q --depth 1 https://github.com/emscripten-core/emsdk "$EMSDK"
  "$EMSDK/emsdk" install "$EMSCRIPTEN_VERSION" >/dev/null
  "$EMSDK/emsdk" activate "$EMSCRIPTEN_VERSION" >/dev/null
  # shellcheck disable=SC1091
  source "$EMSDK/emsdk_env.sh" >/dev/null 2>&1
fi
emcc --version | head -1

# 3. static libngspice for wasm32. --with-ngshared makes configure add
# -shared to every sub-library (STATIC), which libtool cannot do for
# Emscripten; build everything static instead.
BUILD="$SRC/build-wasm"
mkdir -p "$BUILD"
(cd "$BUILD" && emconfigure ../configure --host=wasm32-unknown-emscripten \
   --enable-static --disable-shared "${CONFIG[@]}" CFLAGS="-O2" > configure.log 2>&1) ||
  { tail -20 "$BUILD/configure.log" >&2; exit 1; }
(cd "$BUILD" && emmake make -j"$(nproc)" STATIC= libngspice_la_CFLAGS= \
   libngspice_la_LDFLAGS=-static > make.log 2>&1) ||
  { grep -E "error" "$BUILD/make.log" | head -20 >&2; exit 1; }

# 4. link. HICUM is C++, so link with em++ and exceptions on.
OUT="$ROOT/target/ngspice-wasm"
mkdir -p "$OUT"
EXPORTS=_ngSpice_Init,_ngSpice_Command,_ngSpice_Circ,_ngGet_Vec_Info,_ngSpice_CurPlot
EXPORTS+=,_ngSpice_AllVecs,_ngSpice_AllPlots,_ngSpice_running,_malloc,_free
em++ -O2 -fexceptions "$BUILD/src/.libs/libngspice.a" -o "$OUT/ngspice.mjs" \
  -sMODULARIZE=1 -sEXPORT_ES6=1 -sEXPORT_NAME=createNgspice \
  -sALLOW_MEMORY_GROWTH=1 -sALLOW_TABLE_GROWTH=1 -sENVIRONMENT=web,worker,node \
  -sEXIT_RUNTIME=0 -sEXPORTED_FUNCTIONS="$EXPORTS" \
  -sINCOMING_MODULE_JS_API=wasmBinary,locateFile,print,printErr \
  -sEXPORTED_RUNTIME_METHODS=FS,addFunction,UTF8ToString,stringToNewUTF8,HEAPF64,HEAPU32,HEAP32 \
  2> "$OUT/link.log" || { cat "$OUT/link.log" >&2; exit 1; }
ls -l "$OUT"/ngspice.mjs "$OUT"/ngspice.wasm

# 5. native ngspice from the same patched sources, same features
if [ "$NATIVE" = 1 ]; then
  NB="$SRC/build-native"
  mkdir -p "$NB"
  (cd "$NB" && ../configure "${FEATURES[@]}" CFLAGS=-O2 > configure.log 2>&1 &&
   make -j"$(nproc)" > make.log 2>&1) || { tail -20 "$NB/make.log" >&2; exit 1; }
  mkdir -p "$ROOT/target/ngspice-native"
  cp "$NB/src/ngspice" "$ROOT/target/ngspice-native/ngspice"
  ls -l "$ROOT/target/ngspice-native/ngspice"
fi
