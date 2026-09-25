#!/usr/bin/env bash
# Sets ROOT_INCLUDE_PATH *before* the real binary's own process is created, then execs it.
#
# This has to happen externally, from a wrapper, rather than from any code running inside the
# process: libCore.so is itself a dependency of libroot_dict_shared.so, and per the ELF
# spec's own ordering guarantee, a shared object's dependencies' constructors always run
# before its own -- so libCore.so's own constructor always runs before any code of ours,
# regardless of constructor priority, and it reads and caches ROOT_INCLUDE_PATH that early.
# ROOT/Cling's autoload machinery never sees a value set later, from inside the process, no
# matter how early.
#
# $1/$2 (the real binary and _CROOTData.hh's own runfiles-relative paths) are passed
# explicitly, via this target's own args = ["$(location ...)", ...] in BUILD.bazel -- not
# inferred from $0/this script's own invoked name, and not a package path hardcoded here a
# second time (Bazel itself already knows it, from each label). Nothing about how Bazel
# invokes a script guarantees $0 reflects the target's own name: true for a plain sh_binary
# with no further indirection, false the moment any exists -- confirmed directly,
# use_bash_launcher's own generated launcher execs this script by its own resolved runfiles
# path, which resets $0 to that path, not the invoking target's name, and silently execs the
# wrong binary as a result. That's why this doesn't try $0 at all, and doesn't use
# use_bash_launcher either -- the runfiles library is initialized manually below (via a
# deps = ["@rules_shell//shell/runfiles"] dependency in BUILD.bazel), with the library's own
# official, verbatim init snippet.
#
# $1/$2 themselves are Bazel's own $(location) output: a runfiles-relative path, not
# necessarily a real, resolvable one directly -- rlocation (below) is still needed to turn
# each into an actual on-disk path. The release archive preserves Katydid/Truncate's own
# actual runfiles layout (via pkg_tar's own include_runfiles, see //BUILD.bazel) rather than
# flattening everything, so this same lookup mechanism works unmodified once packaged too.
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
           "locations, from this target's own args = [\"\$(location ...)\", ...] in" \
           "BUILD.bazel), got $#"
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
