#!/usr/bin/env bash
# Tiny, Katydid-specific entry point: resolves root_include_path_wrapper.sh's own location
# via the runfiles library, then execs it with Katydid_bin's own and _CROOTData.hh's own
# locations hardcoded directly here, plus this script's own args forwarded unchanged.
#
# Hardcoded here, in a target-specific script, rather than passed via Bazel's own args
# attribute on a single, shared sh_binary (an earlier attempt): confirmed directly, args
# never gets baked into the underlying file itself -- it's only applied by Bazel's own
# bazel run/test invocation machinery, so it's absent whenever the file is invoked directly
# as a subprocess, which is exactly how this is actually used (e.g. from the packaged
# release archive, or by katydid_stderr_test). Hardcoding the locations directly here needs
# no such assumption at all: this script always knows which binary it's for.
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
  "Source/Executables/Main/Katydid_bin" \
  "Source/Executables/Main/_CROOTData.hh" \
  "$@"
