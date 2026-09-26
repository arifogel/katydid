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
            ctx.actions.run_shell(
                outputs = [out],
                inputs = [f],
                command = "cp -f '{}' '{}'".format(f.path, out.path),
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
