#!/usr/bin/env bash
#
# mayhem/test.sh — behavioral oracle for dev86's ld86 (the fuzz target) via the as86→ld86 toolchain.
#
# UPSTREAM SUITE STATUS: dev86 ships NO runnable unit/functional test suite (tests_found=0). There is
# no `make check`/`make test`; the tests/ directory holds demo C programs that must be compiled with
# the repo's own bcc cross-compiler into 8086 binaries and executed on an 8086 — not runnable in CI.
# (unproto/Makefile:test and libbsd/Makefile:tests are unrelated subcomponent stubs.) So this oracle
# is AUTHORED: a known-answer test (KAT) over the real toolchain path using the upstream-shipped
# fixture tests/hello_world.s —
#   as86 assembles it (byte-exact golden object), ld86 links it (byte-exact golden executable,
#   MINIX a.out magic 01 03), and ld86 must REJECT malformed objects with a non-zero exit.
# All assertions are on OUTPUT BYTES, not exit codes, so a neutered (exit-0) toolchain fails them.
# Binaries are PRE-BUILT by mayhem/build.sh into /mayhem/test-bin (clean, normal flags) — nothing is
# compiled here.
set -uo pipefail

: "${SRC:=/mayhem}"
AS=/mayhem/test-bin/as86
LD=/mayhem/test-bin/ld86
FIX="$SRC/tests/hello_world.s"

# Golden values captured from a trusted clean build (make -C ld ld86 CC=clang, base 20260621);
# verified byte-stable across independent rebuilds.
GOLD_OBJ_SHA=c498942d4b13423256c4ebaf9798ba2e4ad69401133be12f82dc1f6082a9db8f
GOLD_BIN_SHA=73505046822cffb85d9465f9b26c740060beab2c3ed5f55efaccf84c57e34516
GOLD_BIN_MAGIC="0103"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

declare -a NAMES STATUSES MSGS
passed=0; failed=0
record() { # name status message
  NAMES+=("$1"); STATUSES+=("$2"); MSGS+=("$3")
  if [ "$2" = passed ]; then passed=$((passed+1)); else failed=$((failed+1)); echo "FAIL: $1 — $3" >&2; fi
}

# 1) as86 assembles the upstream fixture to the byte-exact golden object
"$AS" -o "$T/hw.o" "$FIX" >/dev/null 2>&1
got_obj=$(sha256sum "$T/hw.o" 2>/dev/null | cut -d' ' -f1)
if [ "$got_obj" = "$GOLD_OBJ_SHA" ]; then record as86_assemble_kat passed "object sha256 matches golden"
else record as86_assemble_kat failed "object sha256 '$got_obj' != golden $GOLD_OBJ_SHA"; fi

# 2) ld86 links the object to the byte-exact golden executable
"$LD" -o "$T/hw" "$T/hw.o" >/dev/null 2>&1
got_bin=$(sha256sum "$T/hw" 2>/dev/null | cut -d' ' -f1)
if [ "$got_bin" = "$GOLD_BIN_SHA" ]; then record ld86_link_kat passed "linked image sha256 matches golden"
else record ld86_link_kat failed "linked sha256 '$got_bin' != golden $GOLD_BIN_SHA"; fi

# 3) linked image carries the MINIX a.out magic (0x01 0x03)
got_magic=$(od -An -tx1 -N2 "$T/hw" 2>/dev/null | tr -d ' \n')
if [ "$got_magic" = "$GOLD_BIN_MAGIC" ]; then record ld86_output_magic passed "a.out magic 01 03 present"
else record ld86_output_magic failed "magic '$got_magic' != $GOLD_BIN_MAGIC"; fi

# 4) ld86 REJECTS a truncated object (non-zero exit, no usable output)
head -c 20 "$T/hw.o" > "$T/trunc.o"
"$LD" -o "$T/z1" "$T/trunc.o" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ] && [ "$(sha256sum "$T/z1" 2>/dev/null | cut -d' ' -f1)" != "$GOLD_BIN_SHA" ]; then
  record ld86_reject_truncated passed "truncated object rejected (exit $rc)"
else record ld86_reject_truncated failed "truncated object NOT rejected (exit $rc)"; fi

# 5) ld86 REJECTS a bad-magic input (non-zero exit)
printf 'NOTANOBJ' > "$T/junk"
"$LD" -o "$T/z2" "$T/junk" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then record ld86_reject_bad_magic passed "bad-magic input rejected (exit $rc)"
else record ld86_reject_bad_magic failed "bad-magic input accepted (exit 0)"; fi

# ── CTRF report ──────────────────────────────────────────────────────────────────────────────────
total=$((passed+failed))
tests_json=""
for i in "${!NAMES[@]}"; do
  [ -n "$tests_json" ] && tests_json+=","
  tests_json+="{\"name\":\"${NAMES[$i]}\",\"status\":\"${STATUSES[$i]}\",\"duration\":0,\"message\":\"${MSGS[$i]}\"}"
done
ctrf_json="{\"results\":{\"tool\":{\"name\":\"dev86-ld86-kat\"},\"summary\":{\"tests\":$total,\"passed\":$passed,\"failed\":$failed,\"pending\":0,\"skipped\":0,\"other\":0},\"tests\":[$tests_json]}}"
printf '%s\n' "$ctrf_json" > "${CTRF_REPORT:-$SRC/ctrf-report.json}"

# stdout marker line (the board/verifier parse this): literal `CTRF ` + the one-line JSON
printf 'CTRF %s\n' "$ctrf_json"
[ "$failed" -eq 0 ]
