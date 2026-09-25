#!/usr/bin/env bash
# Bazel-only wrapper around the real Katydid/Truncate binary (named "<this script's own
# name>_bin", built and placed directly alongside this script -- see BUILD.bazel's own
# comment for why): sets ROOT_INCLUDE_PATH *before* that binary's own process is created,
# then execs it.
#
# This has to happen externally, from a wrapper, rather than from code running inside the
# process itself (as an earlier, in-process constructor hook -- BazelRootIncludePath.cc,
# no longer used -- originally tried): confirmed directly, via strace, that a value set from
# inside the process, no matter how early (including via an explicitly-prioritized
# constructor, guaranteed by the ELF spec to run before any of the main executable's own
# code), never appears in the paths ROOT/Cling's autoload machinery actually attempts.
# libCore.so is itself a dependency of the .so this code used to live in, and per the ELF
# spec's own ordering guarantee, a shared object's dependencies' constructors always run
# before its own -- so libCore.so's own constructor unavoidably runs before any code of ours
# gets a chance to, regardless of priority. It appears to read and cache ROOT_INCLUDE_PATH
# that early. Setting the variable before the process even exists is the only point
# confirmed, directly, to actually work.
#
# Deliberately does not use Bazel's runfiles library, matching CicadaDict_header_local_copy's
# own reasoning (see BUILD.bazel): uses this script's own invoked path directly (see below
# for exactly how, and why not via readlink -f), so this keeps working correctly for a plain
# packaged/relocated copy (release archives, etc.) that doesn't bring a .runfiles tree along
# -- not just from within bazel-bin or a test sandbox.
set -euo pipefail

# Deliberately does NOT resolve symlinks (e.g. via readlink -f): Bazel's own sh_binary, for a
# plain script with no compilation step, exposes its output path as a symlink straight back
# to this script's own original source file, not a renamed/copied file -- fully resolving
# that symlink chain lands on this file's own real name ("root_include_path_wrapper.sh"),
# not the invoking target's name ("Katydid"/"Truncate"), which is exactly the identity this
# script needs (confirmed directly: this is what `bazel run //...:Katydid` actually hit).
# $0 itself, left unresolved, already gives the correct invoked name and (via dirname) the
# correct directory to find the real binary in -- a genuine, non-symlinked sibling file in
# that same directory, whether that's a Bazel output directory or a flat, extracted release
# archive. Trade-off worth being explicit about: this means invoking this script through some
# other, external symlink (e.g. one a person creates themselves elsewhere, pointing at this
# script) would look for the real binary in the wrong place, next to that symlink rather than
# next to this script's own real location. Not a real concern for any way this is actually
# invoked (bazel run/test, or a plain extracted release archive), only a deliberately
# unhandled case.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$(basename "$0")"

# _CROOTData.hh (see CicadaDict_header_local_copy in BUILD.bazel) is copied directly
# alongside this script, in this same package's own bazel-out bin/ directory -- exactly
# SCRIPT_DIR, for both this script and the real binary (see below), since both are built in
# this same Bazel package.
#
# Appends to, rather than replaces, any pre-existing ROOT_INCLUDE_PATH (e.g. one set manually
# for interactive/debug use), so both take effect -- same behavior as the old in-process hook.
if [[ -n "${ROOT_INCLUDE_PATH:-}" ]]; then
  export ROOT_INCLUDE_PATH="${ROOT_INCLUDE_PATH}:${SCRIPT_DIR}"
else
  export ROOT_INCLUDE_PATH="${SCRIPT_DIR}"
fi

exec "${SCRIPT_DIR}/${SCRIPT_NAME}_bin" "$@"
