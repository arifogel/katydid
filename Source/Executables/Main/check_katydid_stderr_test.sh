#!/usr/bin/env bash
# Runs Katydid --help and fails if its stderr contains either of two errors, traced to two
# separate root causes (not one, despite both surfacing through the same dictionary-
# registration/autoload machinery).
#
# The first: TCling::RegisterModule needs to dlopen() the object containing a ROOT
# dictionary (IODict/CicadaDict), and that object used to be Katydid's own main executable
# -- a PIE main executable was never a properly supported dlopen() target in the first
# place. On glibc >= 2.29 this is refused outright (the first error, seen on Ubuntu); on
# toolchains that don't flag the binary DF_1_PIE (seen on AlmaLinux 9's default gcc 11), the
# dlopen() isn't refused but appears to still leave dictionary registration incomplete,
# silently, producing the second error instead -- with no explicit error pointing at the
# actual cause. Fixed by moving the dictionary's own code into a genuine, separate .so (see
# BUILD.bazel's own comment on :libroot_dict_shared.so).
#
# The second, unrelated to the first: Cling's runtime autoloader needs ROOT_INCLUDE_PATH set
# to find _CROOTData.hh when it first encounters certain Cicada types -- but only if it's
# already present in the environment *before* Katydid's own process is created. Confirmed
# directly, via strace, that ROOT_INCLUDE_PATH set from any code running inside the process
# itself -- however early, including from an explicitly-prioritized shared-library
# constructor guaranteed by the ELF spec to run before any of Katydid's own code -- never
# reaches this lookup at all. Fixed by root_include_path_wrapper.sh, which sets it
# externally, before Katydid_bin's own process exists.
#
# --help is used because it's the earliest point at which Katydid's own
# ROOT/Cling initialization -- and therefore either failure, if present --
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
