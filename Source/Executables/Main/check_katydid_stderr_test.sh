#!/usr/bin/env bash
# Runs Katydid --help and fails if its stderr contains either of two known-bad messages: a
# dictionary-registration error from TCling::RegisterModule, or a "Missing FileEntry for
# _CROOTData.hh" autoload error.
#
# The first is guarded against by every Katydid module being a real, standalone .so, each a
# valid dlopen() target for TCling::RegisterModule (see Source/Utility/BUILD.bazel's comment on
# :katydid_utility_lib). The second is guarded against by ROOT_INCLUDE_PATH being set, in the
# environment, before Katydid's process starts (root_include_path_launcher.bzl) - Cling's
# runtime autoloader needs it set before the process is created, since a value set from inside
# the process, however early, is never seen.
#
# --help is used because it's the earliest point where Katydid's ROOT/Cling initialization has
# already run.
set -uo pipefail

KATYDID="$1"

# Exit code isn't checked here -- this test only cares about stderr content.
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
