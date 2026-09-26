"""harvest_runtime_libs: collects every runtime .so/.pcm a binary needs, straight from Bazel's
dependency graph rather than a hand-maintained list or a directory walk over an
already-materialized runfiles tree on disk (which can accumulate stale entries across
incremental builds).

`binary[DefaultInfo].default_runfiles.files` is the same, freshly-computed-every-analysis
depset that already makes `bazel run`/`bazel test` correct, so reading it here reuses the
existing source of truth instead of introducing a new one. Filtering by each file's `.owner`
(a Label, a real graph property) rather than matching Bazel's internal, versioned solib-name
mangling keeps this robust to how Bazel happens to name things internally.

Every harvested .so also gets its RPATH rewritten (patchelf on Linux, install_name_tool on
macOS - see release_binary.bzl's docstring for the macOS-specific steps this needs beyond a
plain RPATH rewrite), not just copied as-is: each one still carries whatever RPATH Bazel baked
in at its original build time (pointing at Bazel's solib-tree paths, meaningless once
repackaged), and library-to-library dependencies among the bundled .so files (e.g.
libscarab.so's dependency on libyaml-cpp.so - not a dependency of Katydid_bin directly, so
invisible to a NEEDED/LC_LOAD_DYLIB-based allowlist or to patching only the top-level binary)
need the same fix. The RPATH used is identical to the top-level binary's in release_binary.bzl
($ORIGIN/../lib:$ORIGIN/../root/lib on Linux, @loader_path/../lib and
@loader_path/../root/lib on macOS): for a file already inside lib/, ../lib round-trips back to
lib/ itself, so one RPATH is correct in both places.
"""

load("@system_libs//:lib_dirs.bzl", "MAC_LIB_DIRS")

# Resolved once, at load time, via this file's repo mapping rather than hardcoded against
# Bazel's internal, version-specific canonical-name mangling (e.g. the "+root_deps+root"-style
# names visible in solib directory paths). Label() only parses/canonicalizes a label string; it
# doesn't require anything at that path to exist.
_ROOT_WORKSPACE_NAME = Label("@root//:BUILD.bazel").workspace_name

# One '-add_rpath <dir>' per macOS Homebrew formula directory (see tools/system_deps.bzl's
# comment on mac_lib_dirs): Boost/FFTW/MatIO's .dylib files are never reachable from binaries'
# runfiles (they're a plain `deps` of a cc_library wrapped into a cc_shared_library - see
# Source/Utility/BUILD.bazel - not a `dynamic_deps` sibling the way this rule's harvesting is),
# so there's nothing to bundle into lib/; the release archive instead has to find Homebrew's
# copy on whatever machine runs it, the same non-hermetic trade-off Linux already makes for
# these three libraries via apt/dnf's default search paths.
_MAC_EXTRA_RPATH_FLAGS = " ".join(["-add_rpath '{}'".format(d) for d in MAC_LIB_DIRS])

def _harvest_runtime_libs_impl(ctx):
    # Resolved via a private constraint-value attribute, the standard way for a rule
    # implementation (not a macro - select() isn't usable directly inside one) to branch on
    # target OS.
    is_macos = ctx.target_platform_has_constraint(ctx.attr._macos_constraint[platform_common.ConstraintValueInfo])

    outputs = []
    seen_basenames = {}
    for binary in ctx.attr.binaries:
        for f in binary[DefaultInfo].default_runfiles.files.to_list():
            # @root is bundled wholesale into the release archive's root/ subdirectory
            # separately (see //tools:root.bzl's all_files filegroup) - anything owned by it
            # here would be a duplicate, and ROOT's libraries deliberately don't live
            # alongside Katydid's in lib/ (see this repo's top-level BUILD.bazel comment on
            # //:katydid_release for why).
            if f.owner != None and f.owner.workspace_name == _ROOT_WORKSPACE_NAME:
                continue
            if not (f.basename.endswith(".so") or f.basename.endswith(".pcm")):
                continue
            if f.basename in seen_basenames:
                # Two different runfiles resolving to the same basename shouldn't happen for a
                # real set of distinct shared libraries/PCMs - keep the first found rather
                # than fail outright, since a harmless coincidence (e.g. the same library
                # reachable from more than one binary) is more likely than a genuine collision
                # worth hard-failing the build over.
                continue
            seen_basenames[f.basename] = True

            out = ctx.actions.declare_file(ctx.label.name + "/" + f.basename)
            if f.basename.endswith(".so"):
                if is_macos:
                    # See release_binary.bzl's docstring for why each of these three steps is
                    # needed on macOS specifically (unlike Linux's single patchelf
                    # --set-rpath call, with no dependency-reference or signature concerns).
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
                    # --set-rpath, not --add-rpath: replaces this .so's Bazel-baked-in RPATH
                    # outright (see this file's docstring for why it's meaningless here)
                    # rather than appending to it. patchelf is built from source by the
                    # @patchelf module (see MODULE.bazel), not assumed to be a preinstalled
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
        "binaries": attr.label_list(mandatory = True, doc = "cc_binarys to harvest runtime .so/.pcm files from."),
        # Private, not user-facing: lets the rule implementation branch on target OS (a plain
        # rule, unlike release_binary.bzl's genrule-based macro, can't use select() directly in
        # its implementation function - this constraint-value attribute is the standard way
        # around that).
        "_macos_constraint": attr.label(default = Label("@platforms//os:macos")),
        # Only used on the Linux branch above; harmless to build unconditionally (see
        # release_binary.bzl's own use of @patchelf for the equivalent, select()-scoped case).
        "_patchelf": attr.label(default = Label("@patchelf//:patchelf"), executable = True, cfg = "exec"),
    },
    doc = "Collects every non-@root .so/.pcm file reachable from binaries' runfiles, flat.",
)
