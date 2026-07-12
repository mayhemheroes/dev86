#!/usr/bin/env bash
#
# mayhem/build.sh — build the dev86 fuzz target (ld86) + the behavioral test toolchain.
#
# dev86 is the bcc/8086 development toolchain (K&R C, Makefile build via ./make.fil). The fuzz
# TARGET is `ld86`, the linker: it parses MINIX/bcc a.out relocatable object files
# (ld/readobj.c, ld/table.c, ld/typeconv.c, ld/writex86.c) and links an executable image. It is a
# file-input CLI binary — Mayhem drives it directly with `@@`, so there is no libFuzzer harness /
# standalone driver to compile; the sanitized binary itself is the run-once reproducer.
#
# Two independent builds:
#   (1) SANITIZED ld86  -> /mayhem/ld86            (ASan+UBSan, DWARF<4)  — the fuzz target
#   (2) CLEAN as86+ld86 -> /mayhem/test-bin/*      (normal flags)         — the test.sh oracle toolchain
#
# UBSan relaxations (narrow, benign, fire on EVERY input so they'd otherwise block fuzzing):
#   * alignment  — the object-file readers cast the raw byte buffer to packed structs
#                  (readobj.c/table.c/writex86.c); misaligned reads are benign on x86.
#   * null       — ld/writex86.c defines offsetof(s,m) as ((int)&((s*)0)->m); that null-base
#                  member-address idiom trips UBSan's `null` check on every emit.
# Everything else (all of ASan; the rest of UBSan) stays HALTING, so real memory/UB bugs in the
# parser are still caught (they are — mutated objects SEGV under ASan: productive findings).
# Compiled at -O0: at -O/-O2 clang keeps the benign offsetof null-check even with -fno-sanitize=null,
# so -O0 is required for the relaxation to actually take (and it yields fine binary coverage in Mayhem).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC MAYHEM_JOBS

cd "$SRC"

# Bootstrap the tree: generate make.fil + per-subdir version.h + the ld/ar.h symlink, and build as86
# (only ever built clean — the oracle uses it to assemble). Idempotent: a re-run just no-ops the make.
# Serial (no -j): the top Makefile's make.fil generation shares tmp files (tmp.sed/tmp.mak) and is NOT
# parallel-safe — a `-j` bootstrap races two make.fil generations and dies on `mv: cannot stat make.tmp`.
make as86 ld86 CC="$CC"
mkdir -p /mayhem/test-bin
cp bin/as86 /mayhem/test-bin/

# ── (2) CLEAN ld86 for the behavioral oracle (project's normal flags) ────────────────────────────
# Explicit clean+rebuild so the oracle toolchain is byte-deterministic regardless of prior tree state
# (this is the exact build path the golden KAT hashes in mayhem/test.sh were captured from).
make -C ld clean
make -C ld ld86 CC="$CC"
cp ld/ld86 /mayhem/test-bin/ld86

# ── (1) SANITIZED ld86 — the fuzz target ─────────────────────────────────────────────────────────
# Relax only the two benign always-firing UBSan checks; keep the rest (+ all ASan) halting.
FUZZ_SAN="$SANITIZER_FLAGS -fno-sanitize=alignment,null"
make -C ld clean
make -C ld ld86 CC="$CC" \
     CFLAGS="-O0 $FUZZ_SAN $DEBUG_FLAGS" \
     LDFLAGS="$FUZZ_SAN"
cp ld/ld86 /mayhem/ld86

echo "build.sh OK: /mayhem/ld86 (sanitized) + /mayhem/test-bin/{as86,ld86} (clean)"
