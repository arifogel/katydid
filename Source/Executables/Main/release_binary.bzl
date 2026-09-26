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

On macOS, the same RPATH rewrite is done with install_name_tool instead of patchelf, which
needs several more steps than patchelf's single --set-rpath: (1) every existing LC_RPATH entry
has to be deleted individually (parsed from `otool -l`'s own load-command dump - there's no
"replace all" flag) before the new ones are added; (2) unlike Linux's ELF NEEDED entries (which
are already resolved by bare soname, so patchelf never has to touch them), a dependency
reference can be an absolute build-time path rather than @rpath-relative depending on how it
was linked, so this rewrites every non-system dependency reference (skipping /usr/lib and
/System, which are never bundled here) to @rpath/<basename> via `install_name_tool -change`,
whatever form it started in - a harmless no-op if it was already correct; (3) install_name_tool
invalidates whatever ad hoc code signature the linker attached, and Apple Silicon's kernel
refuses to execute an unsigned (or invalidly-signed) Mach-O binary at all, unlike Intel Macs
which tolerated this - so the binary is re-signed ad hoc (`codesign --sign -`) as the final
step, not an optional cleanup.
"""

def release_binary(name, real_bin_label, final_bin_name):
    """Defines <name>_bin (RPATH-patched copy of real_bin_label) and <name> (wrapper script).

    Both are meant to be packaged into //:katydid_release's own bin/ prefix, renamed to bin/
    <name> and bin/<final_bin_name> respectively (see BUILD.bazel's own pkg_files renames) -
    alongside a sibling lib/ and root/ (ROOT's own, fully bundled tarball) this wrapper's own
    RPATH/ROOTSYS point at.

    Args:
        name: public name; the wrapper script (outs = [name]) is named exactly this.
        real_bin_label: label of the real, unpatched cc_binary to patch and wrap (e.g.
            ":Katydid_bin").
        final_bin_name: the patched binary's own final name once packaged (e.g. "Katydid_bin")
            - baked directly into the wrapper script's own exec line, since the packaging
            step's own rename (this target's own internal name, name + "_bin", to
            final_bin_name) happens after this script is generated, not before. Passed
            explicitly, not derived from name, so the two can never silently drift apart.
    """
    patched_name = name + "_bin"

    # --set-rpath, not --add-rpath: replaces Bazel's own build-time RPATH outright (see this
    # file's own docstring for why that RPATH is meaningless here), rather than appending to
    # it. $ORIGIN is relative to bin/<final_bin_name> itself: ../lib and ../root/lib are its
    # sibling directories in the release archive's own flat layout.
    native.genrule(
        name = patched_name + "_patchelf",
        srcs = [real_bin_label],
        outs = [patched_name],
        cmd = select({
            "@platforms//os:macos": """
cp $(location """ + real_bin_label + """) $@
chmod +w $@
# Rewrite every non-system dependency reference to @rpath/<basename> - see this file's own
# docstring for why this (unlike Linux's bare-soname NEEDED entries) can't be skipped. Every
# shell-level dollar sign below is doubled: genrule's own cmd attribute expands even a bare
# dollar sign inside what becomes a shell comment (see this file's own use of a doubled
# $$ORIGIN below, and the wrapper genrule further down) as an attempted Make-variable
# reference, so a literal shell/awk dollar sign has to be escaped the same way $@ itself does
# not (that one is Bazel's own genrule output-file variable, deliberately left single).
otool -L $@ | tail -n +2 | awk '{print $$1}' | while read -r dep; do
  case "$$dep" in
    /usr/lib/*|/System/*) ;;
    *) install_name_tool -change "$$dep" "@rpath/$$(basename "$$dep")" $@ ;;
  esac
done
# install_name_tool has no --set-rpath equivalent: delete every existing LC_RPATH entry
# first (Bazel's own build-time ones are meaningless once repackaged here), then add the two
# this release archive's own flat layout needs. $@ is bin/<final_bin_name>: @loader_path/../lib
# and @loader_path/../root/lib are its sibling lib/ and root/lib directories.
for rp in $$(otool -l $@ | awk '/cmd LC_RPATH/{getline; getline; print $$2}'); do
  install_name_tool -delete_rpath "$$rp" $@
done
install_name_tool -add_rpath '@loader_path/../lib' -add_rpath '@loader_path/../root/lib' $@
# install_name_tool invalidates the linker's own ad hoc signature; re-sign so Apple Silicon
# will actually run this binary (see this file's own docstring).
codesign --sign - --force $@
""",
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

exec "$$DIR/""" + final_bin_name + """" "$$@"
WRAPPER_EOF
chmod +x $@
""",
    )
