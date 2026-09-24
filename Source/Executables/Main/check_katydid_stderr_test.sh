#!/usr/bin/env bash
# Runs Katydid --help and fails if its stderr contains either of two errors
# both traced back to the same root cause: TCling::RegisterModule needs to
# dlopen() the object containing a ROOT dictionary (IODict/CicadaDict), and
# that object is currently Katydid's own main executable -- a PIE main
# executable was never a properly supported dlopen() target in the first
# place. On glibc >= 2.29 this is refused outright (the first error, seen
# on Ubuntu); on toolchains that don't flag the binary DF_1_PIE (seen on
# AlmaLinux 9's default gcc 11), the dlopen() isn't refused but appears to
# still leave dictionary registration incomplete, silently, producing the
# second error instead -- with no explicit error pointing at the actual
# cause.
#
# --help is used because it's the earliest point at which Katydid's own
# ROOT/Cling initialization -- and therefore this failure, if present --
# has already run.
set -uo pipefail

KATYDID="$1"

# Katydid's own --help exit code isn't asserted on here: this test cares
# about stderr content only, not about --help itself succeeding or not.
STDERR_OUTPUT="$("${KATYDID}" --help 2>&1 >/dev/null || true)"

FAILED=0

if echo "${STDERR_OUTPUT}" | grep -q "cannot dynamically load position-independent executable"; then
  echo "FAIL: Katydid --help's own stderr contains the PIE self-dlopen error:"
  echo "${STDERR_OUTPUT}" | grep -B1 "cannot dynamically load position-independent executable"
  FAILED=1
fi

if echo "${STDERR_OUTPUT}" | grep -q "Missing FileEntry for _CROOTData.hh"; then
  echo "FAIL: Katydid --help's own stderr contains the _CROOTData.hh autoload error:"
  echo "${STDERR_OUTPUT}" | grep -A2 "Missing FileEntry for _CROOTData.hh"
  FAILED=1
fi

if [[ "${FAILED}" -eq 1 ]]; then
  exit 1
fi

echo "PASS: no dictionary-registration/autoload errors in Katydid --help's own stderr"
