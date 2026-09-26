"""Generates release-archive artifacts for one binary: an RPATH-patched copy of the real
binary, plus a portable wrapper script that sets ROOTSYS/ROOT_INCLUDE_PATH before exec-ing it.

This is deliberately separate from root_include_path_launcher.bzl's wrapper, which is built
for Bazel's runfiles tree (via $(rlocationpath ...)/rlocation) and used for `bazel run`/
`bazel test`. The release archive is a plain, flat bin/ + lib/ + root/ + include/ directory
tree extracted from a tarball, with no Bazel runfiles manifest - paths here are computed
relative to the wrapper script's own location ($(dirname "$0")) instead, and the real
binary's RPATH is rewritten (via patchelf) to match that flat layout, since Bazel's build-time
RPATH (a long list of $ORIGIN-relative solib-farm entries and absolute paths into Bazel's
cache) is meaningless once repackaged here.

On macOS, the same rewrite uses install_name_tool instead of patchelf, which needs more steps
than patchelf's single --set-rpath: (1) every existing LC_RPATH entry has to be deleted
individually (parsed from `otool -l`'s load-command dump - there's no "replace all" flag)
before the new ones are added; (2) unlike Linux's ELF NEEDED entries (already resolved by bare
soname), a dependency reference can be an absolute build-time path depending on how it was
linked, so this rewrites every non-system dependency reference (skipping /usr/lib and
/System) to @rpath/<basename> via `install_name_tool -change`; (3) install_name_tool
invalidates the linker's ad hoc code signature, and Apple Silicon refuses to execute an
invalidly-signed Mach-O binary, so the binary is re-signed ad hoc (`codesign --sign -`) as the
final step.
"""

load("@system_libs//:lib_dirs.bzl", "MAC_LIB_DIRS")

# One '-add_rpath <dir>' per macOS Homebrew formula directory - see tools/system_deps.bzl's
# comment on mac_lib_dirs for why: Boost/FFTW/MatIO's .dylib files are never bundled into this
# release archive's lib/, so the binary has to find Homebrew's own copy at runtime instead.
_MAC_EXTRA_RPATH_FLAGS = " ".join(["-add_rpath '{}'".format(d) for d in MAC_LIB_DIRS])

def release_binary(name, real_bin_label, final_bin_name):
    """Defines <name>_bin (RPATH-patched copy of real_bin_label) and <name> (wrapper script).

    Both are meant to be packaged into //:katydid_release's bin/ prefix, renamed to
    bin/<name> and bin/<final_bin_name> respectively (see BUILD.bazel's pkg_files renames) -
    alongside a sibling lib/ and root/ (ROOT's fully bundled tarball) this wrapper's
    RPATH/ROOTSYS point at.

    Args:
        name: public name; the wrapper script (outs = [name]) is named exactly this.
        real_bin_label: label of the real, unpatched cc_binary to patch and wrap (e.g.
            ":Katydid_bin").
        final_bin_name: the patched binary's final name once packaged (e.g. "Katydid_bin") -
            baked into the wrapper script's exec line, since the packaging step's own rename
            (this target's internal name, name + "_bin", to final_bin_name) happens after
            this script is generated. Passed explicitly, not derived from name, so the two
            can never silently drift apart.
    """
    patched_name = name + "_bin"

    # --set-rpath, not --add-rpath: replaces Bazel's build-time RPATH outright (see this
    # file's docstring for why that RPATH is meaningless here) rather than appending to it.
    # $ORIGIN is relative to bin/<final_bin_name>: ../lib and ../root/lib are its sibling
    # directories in the release archive's flat layout.
    native.genrule(
        name = patched_name + "_patchelf",
        srcs = [real_bin_label],
        outs = [patched_name],
        # patchelf is built from source by the @patchelf module (see MODULE.bazel) rather than
        # assumed to be a preinstalled system package - only needed on the default (Linux)
        # branch below, but select() on `tools` works the same way it does on `cmd`.
        tools = select({
            "@platforms//os:macos": [],
            "//conditions:default": ["@patchelf//:patchelf"],
        }),
        cmd = select({
            "@platforms//os:macos": """
cp $(location """ + real_bin_label + """) $@
chmod +w $@
# Rewrite every non-system dependency reference to @rpath/<basename> - see this file's
# docstring for why this (unlike Linux's bare-soname NEEDED entries) can't be skipped. Every
# shell-level dollar sign below is doubled ($$): genrule's cmd attribute expands a bare dollar
# sign as a Make-variable reference even inside what becomes a shell comment, so it has to be
# escaped like any other shell dollar sign here - $@ is the one exception, Bazel's own
# genrule output-file variable, deliberately left single.
otool -L $@ | tail -n +2 | awk '{print $$1}' | while read -r dep; do
  case "$$dep" in
    /usr/lib/*|/System/*) ;;
    *) install_name_tool -change "$$dep" "@rpath/$$(basename "$$dep")" $@ ;;
  esac
done
# install_name_tool has no --set-rpath equivalent: delete every existing LC_RPATH entry
# first (Bazel's build-time ones are meaningless once repackaged here), then add the two this
# release archive's flat layout needs. $@ is bin/<final_bin_name>: @loader_path/../lib and
# @loader_path/../root/lib are its sibling lib/ and root/lib directories.
for rp in $$(otool -l $@ | awk '/cmd LC_RPATH/{getline; getline; print $$2}'); do
  install_name_tool -delete_rpath "$$rp" $@
done
install_name_tool -add_rpath '@loader_path/../lib' -add_rpath '@loader_path/../root/lib' """ + _MAC_EXTRA_RPATH_FLAGS + """ $@
# install_name_tool invalidates the linker's ad hoc signature; re-sign so Apple Silicon will
# run this binary (see this file's docstring).
codesign --sign - --force $@
""",
            "//conditions:default": """
cp $(location """ + real_bin_label + """) $@
chmod +w $@
$(location @patchelf//:patchelf) --set-rpath '$$ORIGIN/../lib:$$ORIGIN/../root/lib' $@
""",
        }),
    )

    # A plain, portable script - no Bazel runfiles library, no rlocation: this has to work
    # standalone once extracted from the release tarball onto any machine.
    native.genrule(
        name = name + "_wrapper_gen",
        outs = [name],
        cmd = """cat > $@ << 'WRAPPER_EOF'
#!/usr/bin/env bash
set -euo pipefail
DIR="$$(cd "$$(dirname "$${BASH_SOURCE[0]}")" && pwd)"

# ROOT's runtime needs this to find its etc/ resources (e.g. etc/gitinfo.txt) and to
# dlopen() libCling.so by its own internal search logic - neither is an ELF NEEDED dependency
# the dynamic linker/RPATH above would resolve.
export ROOTSYS="$$DIR/../root"

# Cling's autoload/autoparse needs this to find Cicada's dictionary headers - see
# Source/Executables/Main/root_include_path_launcher.bzl's comment for the mechanism
# (identical here, just computed relative to this script's location instead of via Bazel's
# rlocation).
if [[ -n "$${ROOT_INCLUDE_PATH:-}" ]]; then
  export ROOT_INCLUDE_PATH="$${ROOT_INCLUDE_PATH}:$$DIR/../include"
else
  export ROOT_INCLUDE_PATH="$$DIR/../include"
fi

exec "$$DIR/""" + final_bin_name + """" "$$@"
WRAPPER_EOF
chmod +x $@
""",
    )
