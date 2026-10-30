#!/usr/bin/env bash
#
# mayhem/build.sh — build rpi-imager's libFuzzer harnesses (upstream's src/test/fuzz/*.cpp, or the corrected copy in mayhem/harness/) and the
# functional test binary mayhem/test.sh runs. Runs in the commit image as `mayhem` in /mayhem, offline
# after the image build: every dependency is an apt -dev package baked into the image, nothing is fetched.
#
# Why not upstream's CMake: it requires Qt >= 6.9 (Debian trixie ships 6.8) and fetches libarchive,
# zstd, xz and zlib as git submodules/FetchContent. The harnesses only need Qt6Core plus the system
# libraries, so each production source a harness links is compiled here directly, with the same
# defines and include paths src/test/fuzz/CMakeLists.txt uses.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
S="$SRC/src"
B="$SRC/build"
OBJ="$B/fuzz-obj"
rm -rf "$OBJ"
mkdir -p "$OBJ/fuzz" "$OBJ/plain" "$B/moc"

MOC=/usr/lib/qt6/libexec/moc
QT_CFLAGS="$(pkg-config --cflags Qt6Core)"
QT_LIBS="$(pkg-config --libs Qt6Core)"
URING_CFLAGS="$(pkg-config --cflags liburing)"
URING_LIBS="$(pkg-config --libs liburing)"
GNUTLS_LIBS="$(pkg-config --libs gnutls)"
ARCHIVE_LIBS="$(pkg-config --libs libarchive)"
ZSTD_LIBS="$(pkg-config --libs libzstd)"
LZMA_LIBS="$(pkg-config --libs liblzma)"
ZLIB_LIBS="$(pkg-config --libs zlib)"
YESCRYPT_DIR=src/dependencies/yescrypt
YESCRYPT_SRCS="$YESCRYPT_DIR/yescrypt-opt.c $YESCRYPT_DIR/yescrypt-common.c $YESCRYPT_DIR/yescrypt-platform.c \
$YESCRYPT_DIR/sha256.c $YESCRYPT_DIR/insecure_memzero.c $YESCRYPT_DIR/yescrypt_wrapper.c"

# What upstream's CMake passes every target: -DHAVE_LIBURING/-DHAVE_GNUTLS, C++20, the glibc assertion mode.
# unsigned-integer-overflow is left out of the sanitizer set: it reports defined behaviour, and upstream
# runs it recoverable with a suppression file, which Mayhem's runtime would not honour.
COMMON_DEFS="-DHAVE_LIBURING -DHAVE_GNUTLS -D_GLIBCXX_ASSERTIONS -fPIC -I$S -I$S/linux -I$S/test/fuzz $QT_CFLAGS $URING_CFLAGS"
CXXFLAGS_ALL="-std=c++20 -O1 $SANITIZER_FLAGS $DEBUG_FLAGS $COMMON_DEFS"
CFLAGS_ALL="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS $COMMON_DEFS"
# libFuzzer flavour: coverage-instrument the production code too, so edges are counted inside it.
FUZZ_COV="-fsanitize=fuzzer-no-link"

# <harness> | MOC | extra production sources | extra link libs
# (the same set src/test/fuzz/CMakeLists.txt registers)
FAT_SRCS="src/devicewrapper.cpp src/devicewrapperpartition.cpp src/devicewrapperfatpartition.cpp \
src/devicewrapperblockcacheentry.cpp src/file_operations.cpp src/linux/file_operations_linux.cpp"
HARNESSES=$(cat <<EOF
fuzz_asn1_length||||
fuzz_bmap||src/fastboot/bmap.cpp|
fuzz_pieeprom||src/fastboot/pieeprom.cpp|
fuzz_sparse_roundtrip||src/fastboot/sparse_encoder.cpp|
fuzz_drivelist||src/drivelist/drivelist_linux.cpp|
fuzz_sparse_bmap||src/fastboot/sparse_encoder.cpp src/fastboot/bmap.cpp|
fuzz_fastboot||src/fastboot/fastboot_protocol.cpp|
fuzz_bootloader_image||src/rpiboot/bootloader_image.cpp|
fuzz_der|moc|src/secureboot.cpp src/linux/acceleratedcryptographichash_gnutls.cpp src/linux/secureboot_crypto_linux.cpp src/secureboot_crypto_common.cpp src/bootimgcreator.cpp src/disk_formatter.cpp $FAT_SRCS|$GNUTLS_LIBS
fuzz_bootfiles||src/rpiboot/bootfiles.cpp|$ARCHIVE_LIBS
fuzz_oslist||src/oslistparser.cpp|
fuzz_imagesize||src/imagesizeparser.cpp|$ARCHIVE_LIBS $ZSTD_LIBS $LZMA_LIBS $ZLIB_LIBS
fuzz_customisation||src/customization_generator.cpp src/dependencies/sha256crypt/sha256crypt.c $YESCRYPT_SRCS|
fuzz_customisation_gen||src/customization_generator.cpp src/dependencies/sha256crypt/sha256crypt.c $YESCRYPT_SRCS|
fuzz_blconfig||src/eeprom_repo_override.cpp|
fuzz_ringbuffer||src/ringbuffer.cpp|
fuzz_rowdiff||src/model_row_diff.cpp|
fuzz_fileserver||src/rpiboot/file_server.cpp|
fuzz_configtxt||||
fuzz_rpiboot_uri||||
fuzz_fatdir|moc|$FAT_SRCS mayhem/fat_template_env.cc|
fuzz_parttable|moc|$FAT_SRCS mayhem/fat_template_env.cc|
EOF
)

# Qt moc output for every QObject header a MOC harness links the .cpp of (what AUTOMOC does upstream).
moc_for() {
    local src="$1" h="${1%.cpp}.h" out
    [ -f "$h" ] && grep -q "Q_OBJECT" "$h" || return 0
    out="build/moc/moc_$(basename "${h%.h}").cpp"
    "$MOC" -DHAVE_LIBURING -DHAVE_GNUTLS -I"$S" -I"$S/linux" $QT_CFLAGS "$h" -o "$SRC/$out"
    echo "$out"
}

# One compile job per line: "<flavour> <source> <object>", run in parallel.
JOBS_FILE="$B/jobs.txt"
: > "$JOBS_FILE"
add_job() { # flavour src
    local obj="$OBJ/$1/$(echo "${2#"$SRC"/}" | tr '/' '_').o"
    grep -qF " $obj" "$JOBS_FILE" || echo "$1 $2 $obj" >> "$JOBS_FILE"
}
add_job_cxx_harness() { add_job fuzz "$1"; add_job plain "$1"; }

LINK_FILE="$B/links.txt"
: > "$LINK_FILE"
while IFS='|' read -r name moc srcs libs; do
    [ -n "$name" ] || continue
    # A corrected copy under mayhem/harness/ replaces the upstream harness of the same name (the
    # upstream file stays untouched; each copy's header says what differs).
    harness="src/test/fuzz/$name.cpp"
    [ -f "mayhem/harness/$name.cpp" ] && harness="mayhem/harness/$name.cpp"
    list="$harness $srcs"
    if [ -n "$moc" ]; then
        for s in $srcs; do list="$list $(moc_for "$S/${s#src/}")"; done
    fi
    printf '%s\n' "$name" > "$B/link-$name.name"
    echo "$list" > "$B/link-$name.srcs"
    echo "${libs} $QT_LIBS $URING_LIBS -lpthread -ldl" > "$B/link-$name.libs"
    echo "$name" >> "$LINK_FILE"
    for s in $list; do add_job_cxx_harness "$s"; done
done <<<"$HARNESSES"
add_job_cxx_harness mayhem/lsan_off.cc

compile_job() {
    local flavour="$1" src="$2" obj="$3" cov="" cc
    [ "$flavour" = fuzz ] && cov="$FUZZ_COV"
    case "$src" in
      *.c)  cc="$CC $CFLAGS_ALL $cov";;
      *)    cc="$CXX $CXXFLAGS_ALL $cov";;
    esac
    case "$src" in *drivelist_linux.cpp) cc="$cc -DDRIVELIST_ENABLE_TEST_API";; esac
    $cc -c "$src" -o "$obj"
}
export -f compile_job
export CC CXX CFLAGS_ALL CXXFLAGS_ALL FUZZ_COV
xargs -P "$MAYHEM_JOBS" -L1 bash -c 'compile_job "$@"' _ <"$JOBS_FILE"

# The canonical LLVM run-once driver, as a C object (clang++ would mangle its LLVMFuzzerTestOneInput ref).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"

link_job() { # name
    local name="$1" libs o_fuzz="" o_plain="" src
    libs="$(cat "$B/link-$name.libs")"
    for src in $(cat "$B/link-$name.srcs"); do
        o_fuzz="$o_fuzz $OBJ/fuzz/$(echo "$src" | tr '/' '_').o"
        o_plain="$o_plain $OBJ/plain/$(echo "$src" | tr '/' '_').o"
    done
    $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $FUZZ_COV $LIB_FUZZING_ENGINE $o_fuzz $OBJ/fuzz/mayhem_lsan_off.cc.o $libs -o "/mayhem/$name"
    $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $o_plain $OBJ/plain/mayhem_lsan_off.cc.o "$OBJ/standalone_main.o" $libs -o "/mayhem/$name-standalone"
}
export -f link_job
export OBJ B
xargs -P "$MAYHEM_JOBS" -I{} bash -c 'link_job {}' <"$LINK_FILE"

# The functional oracle mayhem/test.sh runs: upstream's own Catch2 v3 unit tests for the same parsers the
# harnesses fuzz, built with normal flags (no sanitizers) and the system Catch2.
TESTDIR="$B/tests"
rm -rf "$TESTDIR"
mkdir -p "$TESTDIR/obj"
TEST_CXXFLAGS="-std=c++20 -O1 -fPIC -I$S $QT_CFLAGS $COVERAGE_FLAGS"
CATCH_LIBS="-lCatch2Main -lCatch2"
# <test> | production sources | libs
TESTS=$(cat <<EOF
ringbuffer_test|src/ringbuffer.cpp|
bmap_test|src/fastboot/bmap.cpp|
image_size_parser_test|src/imagesizeparser.cpp|$ARCHIVE_LIBS $ZSTD_LIBS $LZMA_LIBS $ZLIB_LIBS
oslist_parser_test|src/oslistparser.cpp|
config_txt_merge_test||
sparse_encoder_test|src/fastboot/sparse_encoder.cpp src/fastboot/bmap.cpp|
pieeprom_test|src/fastboot/pieeprom.cpp|
bootloader_image_test|src/rpiboot/bootloader_image.cpp|
revision_code_test||
EOF
)
build_test() { # test|srcs|libs
    local name srcs libs objs="" s
    IFS='|' read -r name srcs libs <<<"$1"
    for s in $srcs src/test/$name.cpp; do
        $CXX $TEST_CXXFLAGS -c "$s" -o "$TESTDIR/obj/$name-$(echo "$s" | tr '/' '_').o"
        objs="$objs $TESTDIR/obj/$name-$(echo "$s" | tr '/' '_').o"
    done
    $CXX $COVERAGE_FLAGS $objs $CATCH_LIBS $libs $QT_LIBS -lpthread -o "$TESTDIR/$name"
}
export -f build_test
export TESTDIR TEST_CXXFLAGS CATCH_LIBS QT_LIBS COVERAGE_FLAGS CXX
printf '%s\n' "$TESTS" | xargs -P "$MAYHEM_JOBS" -d '\n' -I{} bash -c 'build_test "$1"' _ {}

# FAT32 template the two filesystem harnesses (fuzz_fatdir, fuzz_parttable) read via FUZZ_FAT_TEMPLATE.
python3 "$S/test/fuzz/make_seeds.py" "$B/seeds" >/dev/null

echo "build.sh: harnesses built"
