"""harvest_runtime_libs: collects every runtime .so/.pcm a binary actually needs, straight from
Bazel's own dependency graph - not a hand-maintained list, and not a directory walk over some
already-materialized runfiles tree on disk (which can accumulate stale entries across
incremental builds - confirmed directly as a real, not hypothetical, risk earlier in this same
effort: a `bazel run` that appeared to work broke after a `bazel clean --expunge`, once no
stale state was left to paper over a real gap).

`binary[DefaultInfo].default_runfiles.files` is the same, freshly-computed-every-analysis
depset that already makes `bazel run`/`bazel test` correct - reading it here doesn't introduce
a new source of truth, it reuses the existing one. Filtering by the file's own `.owner` (a
Label, a real graph property) rather than by matching against Bazel's internal, versioned
solib-mangling scheme keeps this robust to how Bazel happens to name things internally.

Every harvested .so also gets its own RPATH rewritten (via patchelf, Linux only - see
release_binary.bzl's own docstring for the same macOS caveat), not just copied as-is: each one
still carries whatever RPATH Bazel baked in at its own original build time (pointing at
Bazel's own _solib_k8 paths, meaningless once repackaged), and library-to-library dependencies
among the bundled .so files themselves (e.g. libscarab.so's own genuine NEEDED entry on
libyaml-cpp.so - not a dependency of Katydid_bin directly, so invisible to a NEEDED-based
allowlist or to only patching the top-level binary) need this fixed too, the same way the
binary itself does. $ORIGIN/../lib:$ORIGIN/../root/lib is used for every harvested .so here,
identical to the top-level binary's own RPATH in release_binary.bzl: for a file already
inside lib/, $ORIGIN/../lib round-trips back to lib/ itself (finding its own siblings), so one
RPATH string is correct in both places.
"""

# Resolved once, at load time, via this file's own repo mapping - not hardcoded against
# Bazel's internal, version-specific canonical-name mangling (e.g. the "+root_deps+root"-style
# names visible in solib directory paths). Label() only parses/canonicalizes a label string; it
# doesn't require anything at that path to exist.
_ROOT_WORKSPACE_NAME = Label("@root//:BUILD.bazel").workspace_name

def _harvest_runtime_libs_impl(ctx):
    outputs = []
    seen_basenames = {}
    for binary in ctx.attr.binaries:
        for f in binary[DefaultInfo].default_runfiles.files.to_list():
            # @root is bundled wholesale into the release archive's own root/ subdirectory
            # separately (see //tools:root.bzl's own all_files filegroup) - anything owned by
            # it here would just be a duplicate, and ROOT's own libraries deliberately don't
            # live alongside Katydid's own in lib/ (see this repo's own top-level BUILD.bazel
            # comment on //:katydid_release for why).
            if f.owner != None and f.owner.workspace_name == _ROOT_WORKSPACE_NAME:
                continue
            if not (f.basename.endswith(".so") or f.basename.endswith(".pcm")):
                continue
            if f.basename in seen_basenames:
                # Two different runfiles resolving to the same basename shouldn't happen for
                # a real set of distinct shared libraries/PCMs - keep the first found, rather
                # than fail outright, since a harmless coincidence (e.g. the same library
                # reachable from more than one of binaries) is more likely than a genuine
                # collision worth hard-failing the build over.
                continue
            seen_basenames[f.basename] = True

            out = ctx.actions.declare_file(ctx.label.name + "/" + f.basename)
            if f.basename.endswith(".so"):
                # --set-rpath, not --add-rpath: replaces this .so's own, Bazel-baked-in RPATH
                # outright (see this file's own docstring for why it's meaningless here),
                # rather than appending to it.
                command = (
                    "cp -f '{src}' '{out}' && chmod +w '{out}' && " +
                    "patchelf --set-rpath '$ORIGIN/../lib:$ORIGIN/../root/lib' '{out}'"
                ).format(src = f.path, out = out.path)
            else:
                command = "cp -f '{}' '{}'".format(f.path, out.path)
            ctx.actions.run_shell(
                outputs = [out],
                inputs = [f],
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
    },
    doc = "Collects every non-@root .so/.pcm file reachable from binaries' own runfiles, flat.",
)
