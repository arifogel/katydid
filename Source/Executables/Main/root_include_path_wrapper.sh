#!/usr/bin/env bash
# Sets ROOT_INCLUDE_PATH *before* the real binary's own process is created, then execs it
# (see BUILD.bazel for how the real binary, named "<this script's own name>_bin", is built).
#
# This has to happen externally, from a wrapper, rather than from any code running inside the
# process: libCore.so is itself a dependency of libroot_dict_shared.so, and per the ELF
# spec's own ordering guarantee, a shared object's dependencies' constructors always run
# before its own -- so libCore.so's own constructor always runs before any code of ours,
# regardless of constructor priority, and it reads and caches ROOT_INCLUDE_PATH that early.
# ROOT/Cling's autoload machinery never sees a value set later, from inside the process, no
# matter how early.
#
# Uses Bazel's own runfiles library (via a deps = ["@rules_shell//shell/runfiles"] dependency
# in BUILD.bazel) to locate both the real binary and _CROOTData.hh: the release archive
# preserves Katydid/Truncate's own actual runfiles layout (via pkg_tar's own
# include_runfiles, see //BUILD.bazel) rather than flattening everything, so the same lookup
# mechanism Bazel itself uses within the build tree works unmodified once packaged too.
#
# Initialized manually below, with the library's own, official, verbatim init snippet, rather
# than via sh_binary's own use_bash_launcher attribute: that attribute's own generated
# launcher looks for the runfiles library at this same bazel_tools-rooted path too, but
# doesn't itself add the dependency that makes the library available there in the first
# place -- confirmed directly, it produced "ERROR: cannot find bazel_tools/tools/bash/
# runfiles/runfiles.bash" until this file's own explicit deps line (in BUILD.bazel) was
# added.
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

SCRIPT_NAME="$(basename "$0")"

ROOT="$(runfiles_current_repository)"
if [[ -z "${ROOT}" ]]; then
  ROOT="_main"
fi

REAL_BIN="$(rlocation "${ROOT}/Source/Executables/Main/${SCRIPT_NAME}_bin")"
CROOT_DATA_HH="$(rlocation "${ROOT}/Source/Executables/Main/_CROOTData.hh")"
CROOT_DATA_DIR="$(dirname "${CROOT_DATA_HH}")"

# Appends to, rather than replaces, any pre-existing ROOT_INCLUDE_PATH (e.g. one set manually
# for interactive/debug use), so both take effect.
if [[ -n "${ROOT_INCLUDE_PATH:-}" ]]; then
  export ROOT_INCLUDE_PATH="${ROOT_INCLUDE_PATH}:${CROOT_DATA_DIR}"
else
  export ROOT_INCLUDE_PATH="${CROOT_DATA_DIR}"
fi

exec "${REAL_BIN}" "$@"
