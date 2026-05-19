#!/bin/bash
set -e
BASE="$(cd "$(dirname "$0")" && pwd)"
DL="$BASE/downloads"
DEPS="$BASE/deps"
NPROC=$(nproc)

CC="zig cc -target x86_64-linux-gnu -mcpu=x86_64"
CXX="zig c++ -target x86_64-linux-gnu -mcpu=x86_64"
AR="zig ar"

build_zstd() {
    echo "=== Building zstd ==="
    local SRC="$DL/zstd-1.5.7/lib"
    local BUILD="$DL/zstd-1.5.7/build-zig"
    mkdir -p "$BUILD"
    find "$SRC" -name "*.c" | while read f; do
        local obj="$BUILD/$(basename "$f" .c).o"
        $CC -O2 -DZSTD_STATIC_LINKING_ONLY -DZSTD_LIB_COMPRESSION=1 -DZSTD_LIB_DICT_BUILD=1 \
            -I"$SRC" -I"$SRC/common" -c "$f" -o "$obj"
    done
    $AR rcs "$BUILD/libzstd.a" "$BUILD"/*.o
    cp "$BUILD/libzstd.a" "$DEPS/lib/libzstd.a"
    echo "zstd done: $(du -sh "$DEPS/lib/libzstd.a")"
}

build_snappy() {
    echo "=== Building snappy ==="
    local SRC="$DL/snappy-1.2.2"
    local BUILD="$DL/snappy-1.2.2/build-zig"
    mkdir -p "$BUILD"
    for f in snappy.cc snappy-sinksource.cc snappy-stubs-internal.cc snappy-c.cc; do
        local obj="$BUILD/$(basename "$f" .cc).o"
        $CXX -O2 -std=c++17 -DNDEBUG \
            -I"$SRC" -c "$SRC/$f" -o "$obj"
    done
    $AR rcs "$BUILD/libsnappy.a" "$BUILD"/*.o
    cp "$BUILD/libsnappy.a" "$DEPS/lib/libsnappy.a"
    echo "snappy done: $(du -sh "$DEPS/lib/libsnappy.a")"
}

build_rocksdb() {
    echo "=== Building rocksdb ==="
    local SRC="$DL/rocksdb-11.1.1"
    local BUILD="$DL/rocksdb-11.1.1/build-zig"
    mkdir -p "$BUILD"

    # Collect all .cc files excluding test/bench/tools/examples/fuzz
    local SRCS=$(find "$SRC" -name "*.cc" \
        -not -path "*/test/*" \
        -not -path "*/bench*/*" \
        -not -path "*/tools/*" \
        -not -path "*/examples/*" \
        -not -path "*/fuzz/*" \
        -not -path "*/unity/*" \
        -not -name "*test*" \
        -not -name "*bench*")

    local count=0
    local total=$(echo "$SRCS" | wc -l)
    for f in $SRCS; do
        count=$((count + 1))
        local rel="${f#$SRC/}"
        local obj="$BUILD/${rel%.cc}.o"
        mkdir -p "$(dirname "$obj")"
        $CXX -O2 -std=c++20 -fPIC -DNDEBUG -DROCKSDB_PLATFORM_POSIX -DOS_LINUX \
            -DROCKSDB_LIB_IO_POSIX -DZSTD -DSNAPPY \
            -DZSTD_STATIC_LINKING_ONLY \
            -I"$SRC" -I"$SRC/include" \
            -I"$DEPS/include/.." \
            -I"$DL/zstd-1.5.7/lib" \
            -I"$DL/snappy-1.2.2" \
            -c "$f" -o "$obj" &
        # Throttle parallelism
        if [ $((count % NPROC)) -eq 0 ]; then
            wait
        fi
        [ $((count % 50)) -eq 0 ] && echo "  rocksdb: $count/$total files compiled"
    done
    wait
    echo "  rocksdb: $count/$total files compiled"

    find "$BUILD" -name "*.o" > "$BUILD/objs.txt"
    $AR rcs "$BUILD/librocksdb.a" $(cat "$BUILD/objs.txt")
    cp "$BUILD/librocksdb.a" "$DEPS/lib/librocksdb.a"
    echo "rocksdb done: $(du -sh "$DEPS/lib/librocksdb.a")"
}

build_zstd
build_snappy
build_rocksdb
echo "=== All done ==="
