"""Generates release-archive artifacts for one binary: an RPATH-patched copy of the real
binary, plus a portable wrapper script that sets ROOTSYS/ROOT_INCLUDE_PATH before exec-ing it.

The release archive is a plain, flat bin/ + lib/ + root/ + include/ directory tree extracted
from a tarball, with no Bazel runfiles manifest - paths here are computed relative to the
wrapper script's own location ($(dirname "$0")) instead, and the real binary's RPATH is
rewritten via patchelf to match that flat layout. Bazel's build-time RPATH is a long list of
$ORIGIN-relative solib-farm entries and absolute paths into Bazel's cache, meaningless once
repackaged here.

On macOS, the same rewrite uses install_name_tool, in three steps: (1) every existing LC_RPATH
entry is deleted individually (parsed from `otool -l`'s load-command dump) before the new ones
are added; (2) a Mach-O dependency reference can be an absolute build-time path depending on how
it was linked, so every non-system dependency reference (skipping /usr/lib and /System) is
rewritten to @rpath/<basename> via `install_name_tool -change`; (3) install_name_tool
invalidates the linker's ad hoc code signature, and Apple Silicon refuses to execute an
invalidly-signed Mach-O binary, so the binary is re-signed ad hoc (`codesign --sign -`) as the
final step.
"""

load("@binary_deps//:lib_dirs.bzl", "MAC_EXTRA_RPATH_FLAGS")

def release_binary(name, real_bin_label, final_bin_name, visibility = None):
    """Defines <name>_bin (RPATH-patched copy of real_bin_label) and <name> (wrapper script).

    Both are meant to be packaged into //:katydid_release's bin/ prefix, renamed to
    bin/<name> and bin/<final_bin_name> respectively, alongside a sibling lib/ and root/
    (ROOT's fully bundled tarball) this wrapper's RPATH/ROOTSYS point at.

    Args:
        name: public name; the wrapper script (outs = [name]) is named exactly this.
        real_bin_label: label of the real, unpatched binary to patch and wrap (e.g.
            ":Katydid_bin").
        final_bin_name: the patched binary's final packaged name (e.g. "Katydid_bin"), baked
            into the wrapper script's exec line. Passed explicitly rather than derived from
            name, since the packaging step renames name + "_bin" to final_bin_name after this
            script is generated.
        visibility: applied to both <name>_bin and <name>.
    """
    patched_name = name + "_bin"

    # Replaces Bazel's build-time RPATH entries with a single relative RPATH entry suitable for
    # the portable release archive (see this file's docstring for why the original is
    # meaningless here). $ORIGIN is relative to bin/<final_bin_name>: ../lib and ../root/lib
    # are its sibling directories in the release archive's flat layout.
    native.genrule(
        name = patched_name + "_patchelf",
        srcs = [real_bin_label],
        outs = [patched_name],
        visibility = visibility,
        # patchelf is only needed on the Linux branch below.
        tools = select({
            "@platforms//os:macos": [],
            "//conditions:default": ["@patchelf//:patchelf"],
        }),
        cmd = select({
            "@platforms//os:macos": """
cp $(location """ + real_bin_label + """) $@
chmod +w $@
# Rewrites every non-system dependency reference to @rpath/<basename> (see this file's
# docstring for the Mach-O-specific reason this step is needed).
# $$ below is a literal shell $$: genrule's cmd expands a bare $$ even inside a shell comment,
# so it must be escaped like any other shell $$ here - $@ is the one exception (Bazel's own
# genrule output-file variable).
otool -L $@ | tail -n +2 | awk '{print $$1}' | while read -r dep; do
  case "$$dep" in
    /usr/lib/*|/System/*) ;;
    *) install_name_tool -change "$$dep" "@rpath/$$(basename "$$dep")" $@ ;;
  esac
done
# Deletes every existing LC_RPATH entry first, then adds the two this release archive's flat
# layout needs. $@ is bin/<final_bin_name>: @loader_path/../lib and @loader_path/../root/lib
# are its sibling lib/ and root/lib directories.
for rp in $$(otool -l $@ | awk '/cmd LC_RPATH/{getline; getline; print $$2}'); do
  install_name_tool -delete_rpath "$$rp" $@
done
install_name_tool -add_rpath '@loader_path/../lib' -add_rpath '@loader_path/../root/lib' """ + MAC_EXTRA_RPATH_FLAGS + """ $@
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

    # A plain, portable script: works standalone once extracted from the release tarball onto
    # any machine.
    native.genrule(
        name = name + "_wrapper_gen",
        outs = [name],
        visibility = visibility,
        cmd = """cat > $@ << 'WRAPPER_EOF'
#!/usr/bin/env bash
set -euo pipefail
DIR="$$(cd "$$(dirname "$${BASH_SOURCE[0]}")" && pwd)"

# ROOT's runtime uses this to find its etc/ resources (e.g. etc/gitinfo.txt) and to dlopen()
# libCling.so via its own internal search logic, independent of the dynamic linker/RPATH above.
export ROOTSYS="$$DIR/../root"

# Cling's autoload/autoparse needs this to find Cicada's dictionary headers, computed here
# relative to this script's own location.
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
