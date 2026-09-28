"""harvest_runtime_libs collects every runtime .so/.pcm a binary needs, from Bazel's dependency
graph.

`binary[DefaultInfo].default_runfiles.files` is the same depset `bazel run`/`bazel test` use.
Filtering by each file's `.owner` (a Label) avoids depending on Bazel's internal solib-name
mangling.

Every harvested .so gets its RPATH rewritten (patchelf on Linux, install_name_tool on macOS):
each carries whatever RPATH Bazel baked in at its original build time, pointing at Bazel's
solib-tree paths, meaningless once repackaged. Library-to-library dependencies among the bundled
.so files need the same fix. The same RPATH is used for the top-level binary and for a file
already inside lib/, since ../lib round-trips back to lib/ itself:
$ORIGIN/../lib:$ORIGIN/../root/lib on Linux, @loader_path/../lib and @loader_path/../root/lib on
macOS.
"""

load("@binary_deps//:lib_dirs.bzl", "MAC_EXTRA_RPATH_FLAGS")

# True for "libfoo.so" and any SONAME-versioned name derived from it ("libfoo.so.3",
# "libfoo.so.1.75.0", ...).
def _is_shared_library(basename):
    idx = basename.find(".so")
    if idx == -1:
        return False
    suffix = basename[idx + len(".so"):]
    if suffix == "":
        return True
    if not suffix.startswith("."):
        return False
    return all([part.isdigit() for part in suffix[1:].split(".")])

# The real workspace names, from this file's repo mapping (not Bazel's internal,
# version-specific canonical-name mangling, e.g. the "+root_deps+root"-style names visible in
# solib directory paths).
_ROOT_WORKSPACE_NAME = Label("@root//:BUILD.bazel").workspace_name
_MACOS_LIBS_WORKSPACE_NAME = Label("@macos_libs//:BUILD.bazel").workspace_name
_UBUNTU_LIBS_WORKSPACE_NAME = Label("@ubuntu_libs//:BUILD.bazel").workspace_name

def _harvest_runtime_libs_impl(ctx):
    is_macos = ctx.target_platform_has_constraint(ctx.attr._macos_constraint[platform_common.ConstraintValueInfo])

    outputs = []
    seen_basenames = {}
    for binary in ctx.attr.binaries:
        for f in binary[DefaultInfo].default_runfiles.files.to_list():
            # @root is bundled wholesale into the release archive's root/ subdirectory
            # separately, so anything owned by it here would be a duplicate. @macos_libs/
            # @ubuntu_libs are excluded too: on those platforms, Boost/FFTW/MatIO are expected to
            # already be present on the machine that runs the release archive. This also
            # sidesteps a RHEL-family packaging quirk on AlmaLinux: boost-devel there ships at
            # least one unversioned name (libboost_thread.so) as a plain linker script, which
            # patchelf below refuses to touch. @almalinux_libs's Boost/FFTW/MatIO cc_imports
            # reference real, working SONAME-level files instead, so it isn't excluded.
            if f.owner != None and f.owner.workspace_name in (_ROOT_WORKSPACE_NAME, _MACOS_LIBS_WORKSPACE_NAME, _UBUNTU_LIBS_WORKSPACE_NAME):
                continue
            if not (_is_shared_library(f.basename) or f.basename.endswith(".pcm")):
                continue
            if f.basename in seen_basenames:
                # Same basename from two different runfiles shouldn't happen for a real set of
                # distinct shared libraries/PCMs; keeping the first found covers the harmless
                # case (the same library reachable from more than one binary).
                continue
            seen_basenames[f.basename] = True

            out = ctx.actions.declare_file(ctx.label.name + "/" + f.basename)
            if _is_shared_library(f.basename):
                if is_macos:
                    # install_name_tool rewrites the id and every dependency reference to
                    # @rpath-relative, drops the stale LC_RPATH entries Bazel baked in, adds the
                    # real ones, and codesign re-signs the binary after modification.
                    command = (
                        "cp -f '{src}' '{out}' && chmod +w '{out}' && " +
                        "install_name_tool -id '@rpath/{base}' '{out}' && " +
                        "otool -L '{out}' | tail -n +2 | awk '{{print $1}}' | while read -r dep; do " +
                        "case \"$dep\" in " +
                        "/usr/lib/*|/System/*) ;; " +
                        "*) install_name_tool -change \"$dep\" \"@rpath/$(basename \"$dep\")\" '{out}' ;; " +
                        "esac; done && " +
                        "for rp in $(otool -l '{out}' | awk '/cmd LC_RPATH/{{getline; getline; print $2}}'); do " +
                        "install_name_tool -delete_rpath \"$rp\" '{out}'; done && " +
                        "install_name_tool -add_rpath '@loader_path/../lib' -add_rpath '@loader_path/../root/lib' {extra} '{out}' && " +
                        "codesign --sign - --force '{out}'"
                    ).format(src = f.path, out = out.path, base = f.basename, extra = MAC_EXTRA_RPATH_FLAGS)
                else:
                    # --set-rpath replaces this .so's Bazel-baked-in RPATH outright (see this
                    # file's docstring for why it's meaningless here).
                    command = (
                        "cp -f '{src}' '{out}' && chmod +w '{out}' && " +
                        "'{patchelf}' --set-rpath '$ORIGIN/../lib:$ORIGIN/../root/lib' '{out}'"
                    ).format(src = f.path, out = out.path, patchelf = ctx.executable._patchelf.path)
            else:
                command = "cp -f '{}' '{}'".format(f.path, out.path)
            ctx.actions.run_shell(
                outputs = [out],
                inputs = [f] if is_macos else [f, ctx.executable._patchelf],
                command = command,
                mnemonic = "HarvestRuntimeLib",
                progress_message = "Harvesting %s for the release archive" % f.basename,
            )
            outputs.append(out)

    return [DefaultInfo(files = depset(outputs))]

harvest_runtime_libs = rule(
    implementation = _harvest_runtime_libs_impl,
    attrs = {
        "binaries": attr.label_list(mandatory = True, doc = "Binary targets to harvest runtime .so/.pcm files from."),
        # Private, not user-facing: lets the rule implementation branch on target OS.
        "_macos_constraint": attr.label(default = Label("@platforms//os:macos")),
        # Only used on the Linux branch above; harmless to build unconditionally.
        "_patchelf": attr.label(default = Label("@patchelf//:patchelf"), executable = True, cfg = "exec"),
    },
    doc = "Collects every .so/.pcm file reachable from binaries' runfiles, flat, excluding @root, @macos_libs, and @ubuntu_libs (see this file's docstring).",
)
