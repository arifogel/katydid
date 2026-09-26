"""Generates release-archive artifacts for one binary: an RPATH-patched copy of the real
binary, plus a portable wrapper script that sets ROOTSYS/ROOT_INCLUDE_PATH before exec-ing it.

This is deliberately separate from root_include_path_launcher.bzl's own wrapper, which is
built for Bazel's own runfiles tree (via $(rlocationpath ...)/rlocation) and used for
`bazel run`/`bazel test`. The release archive is a plain, flat bin/ + lib/ + root/ + include/
directory tree extracted from a tarball, with no Bazel runfiles manifest at all - paths here
are computed relative to the wrapper script's own location ($(dirname "$0")) instead, and the
real binary's own RPATH is rewritten (via patchelf) to match that same flat layout, since
Bazel's own build-time RPATH (a long list of $ORIGIN-relative solib-farm entries and absolute
paths into Bazel's own cache) is meaningless once repackaged here.

Linux only for now (uses patchelf): the macOS equivalent (install_name_tool, which needs
existing LC_RPATH entries deleted before new ones are added, unlike patchelf's single
--set-rpath) isn't implemented yet - untested, and this repo's own CI doesn't build a macOS
release archive yet either. Calling release_binary on macOS fails loudly instead of silently
producing a broken artifact.
"""

def release_binary(name, real_bin_label):
    """Defines <name>_bin (RPATH-patched copy of real_bin_label) and <name> (wrapper script).

    Both are meant to be packaged directly into //:katydid_release's own bin/ prefix - the
    wrapper as bin/<name>, the patched binary as bin/<name>_bin, alongside a sibling lib/ and
    root/ (ROOT's own, fully bundled tarball) this wrapper's own RPATH/ROOTSYS point at.

    Args:
        name: public name; the wrapper script (outs = [name]) is named exactly this.
        real_bin_label: label of the real, unpatched cc_binary to patch and wrap (e.g.
            ":Katydid_bin").
    """
    patched_name = name + "_bin"

    # --set-rpath, not --add-rpath: replaces Bazel's own build-time RPATH outright (see this
    # file's own docstring for why that RPATH is meaningless here), rather than appending to
    # it. $ORIGIN is relative to bin/<name>_bin itself: ../lib and ../root/lib are its sibling
    # directories in the release archive's own flat layout.
    native.genrule(
        name = patched_name + "_patchelf",
        srcs = [real_bin_label],
        outs = [patched_name],
        cmd = select({
            "@platforms//os:macos": "echo 'release_binary: macOS not yet supported (needs install_name_tool, not patchelf) - see release_binary.bzl' >&2; exit 1",
            "//conditions:default": """
cp $(location """ + real_bin_label + """) $@
chmod +w $@
patchelf --set-rpath '$$ORIGIN/../lib:$$ORIGIN/../root/lib' $@
""",
        }),
    )

    # A plain, portable script - no Bazel runfiles library, no rlocation: this has to work
    # standalone once extracted from the release tarball onto an arbitrary machine.
    native.genrule(
        name = name + "_wrapper_gen",
        outs = [name],
        cmd = """cat > $@ << 'WRAPPER_EOF'
#!/usr/bin/env bash
set -euo pipefail
DIR="$$(cd "$$(dirname "$${BASH_SOURCE[0]}")" && pwd)"

# ROOT's own runtime needs this to find its own etc/ resources (e.g. etc/gitinfo.txt) and to
# dlopen() libCling.so by its own internal search logic - neither is a real ELF NEEDED
# dependency the dynamic linker/RPATH above would ever resolve on its own.
export ROOTSYS="$$DIR/../root"

# Cling's own autoload/autoparse needs this to find Cicada's dictionary headers - see
# Source/Executables/Main/root_include_path_launcher.bzl's own comment for the underlying
# mechanism (identical here, just computed relative to this script's own location instead of
# via Bazel's rlocation).
if [[ -n "$${ROOT_INCLUDE_PATH:-}" ]]; then
  export ROOT_INCLUDE_PATH="$${ROOT_INCLUDE_PATH}:$$DIR/../include"
else
  export ROOT_INCLUDE_PATH="$$DIR/../include"
fi

exec "$$DIR/""" + patched_name + """" "$$@"
WRAPPER_EOF
chmod +x $@
""",
    )
