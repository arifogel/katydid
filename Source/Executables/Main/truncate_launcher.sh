#!/usr/bin/env bash
# Tiny, Truncate-specific entry point -- see katydid_launcher.sh's own header comment for
# what this does and why (identical, except for the real binary it hardcodes).
# --- begin runfiles.bash initialization v3 ---
# Copy-pasted from the Bazel Bash runfiles library v3.
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
# shellcheck disable=SC1090
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo>&2 "ERROR: cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v3 ---

ROOT="$(runfiles_current_repository)"
if [[ -z "${ROOT}" ]]; then
  ROOT="_main"
fi

exec "$(rlocation "${ROOT}/Source/Executables/Main/root_include_path_wrapper.sh")" \
  "Source/Executables/Main/Truncate_bin" \
  "Source/Executables/Main/_CROOTData.hh" \
  "$@"
