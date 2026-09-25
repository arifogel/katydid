#!/usr/bin/env bash
# Sets ROOT_INCLUDE_PATH *before* the real binary's own process is created, then execs it
# (see BUILD.bazel for how the real binary, named "<this script's own name>_bin", is built
# and placed directly alongside this script).
#
# This has to happen externally, from a wrapper, rather than from any code running inside the
# process: libCore.so is itself a dependency of libroot_dict_shared.so, and per the ELF
# spec's own ordering guarantee, a shared object's dependencies' constructors always run
# before its own -- so libCore.so's own constructor always runs before any code of ours,
# regardless of constructor priority, and it reads and caches ROOT_INCLUDE_PATH that early.
# ROOT/Cling's autoload machinery never sees a value set later, from inside the process, no
# matter how early.
#
# Deliberately does not use Bazel's runfiles library, matching CicadaDict_header_local_copy's
# own reasoning (see BUILD.bazel): uses this script's own invoked path directly (see below),
# so this keeps working for a plain packaged/relocated copy (release archives, etc.) with no
# .runfiles tree, not just from bazel-bin or a test sandbox.
set -euo pipefail

# Deliberately does NOT resolve symlinks (e.g. via readlink -f): Bazel's own sh_binary, for a
# plain script with no compilation step, exposes its output path as a symlink straight back
# to this script's own original source file, not a renamed or copied one -- resolving that
# symlink lands on this file's own name ("root_include_path_wrapper.sh"), not the invoking
# target's name ("Katydid"/"Truncate"), which is the identity this script actually needs. $0
# itself, left unresolved, already gives the correct invoked name and, via dirname, the
# correct directory to find the real binary in -- a genuine, non-symlinked sibling file
# there, whether that's a Bazel output directory or a flat, extracted release archive.
#
# Trade-off: invoking this script through some other, external symlink (one a person creates
# elsewhere, pointing at this script) would look for the real binary next to that symlink
# rather than this script's own real location. Not a concern for how this is actually invoked
# (bazel run/test, or an extracted release archive) -- a deliberately unhandled case.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$(basename "$0")"

# _CROOTData.hh (see CicadaDict_header_local_copy in BUILD.bazel) is copied directly
# alongside this script, in this same package's own bazel-out bin/ directory -- exactly
# SCRIPT_DIR, for both this script and the real binary (see below), since both are built in
# this same Bazel package.
#
# Appends to, rather than replaces, any pre-existing ROOT_INCLUDE_PATH (e.g. one set manually
# for interactive/debug use), so both take effect.
if [[ -n "${ROOT_INCLUDE_PATH:-}" ]]; then
  export ROOT_INCLUDE_PATH="${ROOT_INCLUDE_PATH}:${SCRIPT_DIR}"
else
  export ROOT_INCLUDE_PATH="${SCRIPT_DIR}"
fi

exec "${SCRIPT_DIR}/${SCRIPT_NAME}_bin" "$@"
