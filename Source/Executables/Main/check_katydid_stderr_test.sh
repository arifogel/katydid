#!/usr/bin/env bash
# Runs Katydid --help and fails if its stderr contains either of two errors, from two
# separate root causes.
#
# First: TCling::RegisterModule dlopen()s the object containing a ROOT dictionary
# (IODict/CicadaDict), which used to be Katydid's own main executable -- not a valid
# dlopen() target for a PIE binary. On glibc >= 2.29 this is refused outright (the first
# error, seen on Ubuntu); on toolchains that don't flag the binary DF_1_PIE (AlmaLinux 9's
# default gcc 11), the dlopen() isn't refused but leaves dictionary registration silently
# incomplete, producing the second error instead. Fixed by making every Katydid module a
# real, standalone .so (see Source/Utility/BUILD.bazel's comment on :katydid_utility_lib for
# the full explanation): each is a valid dlopen() target on its own, so a dictionary's code
# compiled directly into its own module's .so is no longer a PIE executable at all.
#
# Second, unrelated: Cling's runtime autoloader needs ROOT_INCLUDE_PATH set, in the
# environment, before Katydid's process is created, to find _CROOTData.hh. A value set from
# inside the process, however early, is never seen. Fixed in root_include_path_launcher.bzl,
# which sets it externally before Katydid_bin's process exists.
#
# --help is used because it's the earliest point where Katydid's ROOT/Cling initialization
# -- and either failure, if present -- has already run.
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
