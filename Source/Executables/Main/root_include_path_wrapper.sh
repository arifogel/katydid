#!/usr/bin/env bash
# Sets ROOT_INCLUDE_PATH *before* the real binary's own process is created, then execs it.
# Shared logic for both Katydid/Truncate, called by each one's own tiny, target-specific
# launcher (katydid_launcher.sh/truncate_launcher.sh) with that target's own real binary and
# _CROOTData.hh locations hardcoded there -- see either launcher's own header comment for why
# a launcher passing those in, rather than this script inferring or receiving them some other
# way, is what's actually reliable across every context this needs to work in.
#
# This has to happen externally, from a wrapper, rather than from any code running inside the
# process: libCore.so is itself a dependency of libroot_dict_shared.so, and per the ELF
# spec's own ordering guarantee, a shared object's dependencies' constructors always run
# before its own -- so libCore.so's own constructor always runs before any code of ours,
# regardless of constructor priority, and it reads and caches ROOT_INCLUDE_PATH that early.
# ROOT/Cling's autoload machinery never sees a value set later, from inside the process, no
# matter how early.
#
# $1/$2 (the real binary and _CROOTData.hh's own runfiles-relative paths) are Bazel's own
# $(location) output, computed once in each launcher rather than a package path hardcoded
# here a second time -- but still a runfiles-relative path, not necessarily a real,
# resolvable one directly, so rlocation (below) is still needed to turn each into an actual
# on-disk path. The release archive preserves Katydid/Truncate's own actual runfiles layout
# (via pkg_tar's own include_runfiles, see //BUILD.bazel) rather than flattening everything,
# so this same lookup mechanism works unmodified once packaged too.
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

if [[ $# -lt 2 ]]; then
  echo >&2 "ERROR: expected at least 2 args (the real binary's and _CROOTData.hh's own" \
           "locations, from the calling launcher script), got $#"
  exit 1
fi
REAL_BIN_LOCATION="$1"
CROOT_DATA_HH_LOCATION="$2"
shift 2

ROOT="$(runfiles_current_repository)"
if [[ -z "${ROOT}" ]]; then
  ROOT="_main"
fi

REAL_BIN="$(rlocation "${ROOT}/${REAL_BIN_LOCATION}")"
CROOT_DATA_HH="$(rlocation "${ROOT}/${CROOT_DATA_HH_LOCATION}")"
CROOT_DATA_DIR="$(dirname "${CROOT_DATA_HH}")"

# Appends to, rather than replaces, any pre-existing ROOT_INCLUDE_PATH (e.g. one set manually
# for interactive/debug use), so both take effect.
if [[ -n "${ROOT_INCLUDE_PATH:-}" ]]; then
  export ROOT_INCLUDE_PATH="${ROOT_INCLUDE_PATH}:${CROOT_DATA_DIR}"
else
  export ROOT_INCLUDE_PATH="${CROOT_DATA_DIR}"
fi

exec "${REAL_BIN}" "$@"
