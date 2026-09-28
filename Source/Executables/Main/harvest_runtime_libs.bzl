"""harvest_runtime_libs: collects every runtime .so/.pcm a binary needs, from Bazel's dependency
graph.

`binary[DefaultInfo].default_runfiles.files` is the same depset `bazel run`/`bazel test` use.
Filtering by each file's `.owner` (a Label) avoids depending on Bazel's internal solib-name
mangling.

Every harvested .so gets its RPATH rewritten (patchelf on Linux, install_name_tool on macOS -
see release_binary.bzl's docstring for the macOS-specific steps beyond a plain RPATH rewrite):
each carries whatever RPATH Bazel baked in at its original build time (pointing at Bazel's
solib-tree paths, meaningless once repackaged), and library-to-library dependencies among the
bundled .so files (e.g. libscarab.so's dependency on libyaml-cpp.so) need the same fix. The
RPATH used is identical to the top-level binary's in release_binary.bzl
($ORIGIN/../lib:$ORIGIN/../root/lib on Linux, @loader_path/../lib and
@loader_path/../root/lib on macOS): for a file already inside lib/, ../lib round-trips back to
lib/ itself, so one RPATH is correct in both places.
"""

load("@binary_deps//:lib_dirs.bzl", "LIB_DIRS")

# True for "libfoo.so" as well as any real-world SONAME-versioned name derived from it
# ("libfoo.so.3", "libfoo.so.1.75.0", ...) - the form AlmaLinux's actual RPM-provided
# Boost/FFTW/MatIO shared libraries use (see tools/almalinux_libs.bzl's EXTRACTED_LIBS), unlike
# every other .so harvested here, which Bazel itself names as a plain "libfoo.so". A bare
# f.basename.endswith(".so") check misses these entirely - they'd be silently skipped by the
# walk below, never harvested into the release archive at all.
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

# The real workspace name, from this file's repo mapping (not Bazel's internal,
# version-specific canonical-name mangling, e.g. the "+root_deps+root"-style names visible in
# solib directory paths).
_ROOT_WORKSPACE_NAME = Label("@root//:BUILD.bazel").workspace_name

# @macos_libs/@ubuntu_libs (Boost/FFTW/MatIO on macOS/Ubuntu) are excluded from harvesting the
# same way @root is: on those platforms, the release archive relies on these already being
# present on the machine it runs on (Homebrew on macOS, apt's default search paths on Ubuntu -
# see tools/macos_libs.bzl, tools/ubuntu_libs.bzl), so there is nothing to bundle here. This
# also sidesteps a real RHEL-family packaging quirk that would otherwise bite on AlmaLinux:
# boost-devel there ships at least one unversioned name (libboost_thread.so) as a plain linker
# script, not a real ELF file, which patchelf below correctly refuses to touch - which is why
# @almalinux_libs is deliberately NOT excluded here: its Boost/FFTW/MatIO cc_imports reference
# real, working SONAME-level files (see tools/almalinux_libs.bzl), so they harvest and bundle
# cleanly like everything else on AlmaLinux.
_MACOS_LIBS_WORKSPACE_NAME = Label("@macos_libs//:BUILD.bazel").workspace_name
_UBUNTU_LIBS_WORKSPACE_NAME = Label("@ubuntu_libs//:BUILD.bazel").workspace_name

# One '-add_rpath <dir>' per macOS Homebrew formula directory (see tools/binary_deps.bzl's
# LIB_DIRS computation): since Boost/FFTW/MatIO are never bundled into lib/ on macOS (excluded
# above), the release archive instead has to find Homebrew's copy on whatever machine runs it -
# the same non-hermetic trade-off Ubuntu already makes for these three libraries via apt's
# default search paths, which need no equivalent RPATH addition here. Empty (and this flag
# string empty) on Linux, where LIB_DIRS is always [].
_MAC_EXTRA_RPATH_FLAGS = " ".join(["-add_rpath '{}'".format(d) for d in LIB_DIRS])

def _harvest_runtime_libs_impl(ctx):
    is_macos = ctx.target_platform_has_constraint(ctx.attr._macos_constraint[platform_common.ConstraintValueInfo])

    outputs = []
    seen_basenames = {}
    for binary in ctx.attr.binaries:
        for f in binary[DefaultInfo].default_runfiles.files.to_list():
            # @root is bundled wholesale into the release archive's root/ subdirectory
            # separately (see //tools:root.bzl's all_files filegroup and the top-level
            # BUILD.bazel comment on //:katydid_release), so anything owned by it here would
            # be a duplicate. @macos_libs/@ubuntu_libs are excluded for a different reason -
            # see _MACOS_LIBS_WORKSPACE_NAME/_UBUNTU_LIBS_WORKSPACE_NAME above. @almalinux_libs
            # is deliberately not excluded - see the same comment.
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
                    # See release_binary.bzl's docstring for why these three steps are needed
                    # on macOS.
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
                    ).format(src = f.path, out = out.path, base = f.basename, extra = _MAC_EXTRA_RPATH_FLAGS)
                else:
                    # --set-rpath replaces this .so's Bazel-baked-in RPATH outright (see this
                    # file's docstring for why it's meaningless here). patchelf is built from
                    # source by the @patchelf module (see MODULE.bazel), not a preinstalled
                    # system package.
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
