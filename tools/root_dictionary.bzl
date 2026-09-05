"""Generates a ROOT dictionary (.cxx + _rdict.pcm) from a LinkDef header, replacing CMake's
ROOT_GENERATE_DICTIONARY() macro. Used by Katydid's Utility and IO modules, and by Cicada.

This is a real Starlark rule rather than a genrule, because rootcling needs to see every
header transitively reachable from the dictionary headers (via Nymph, Scarab, Boost, and so
on), not just the headers local to the module being built. A genrule has no way to discover
that automatically; only a rule that reads the CcInfo provider of its `deps` can pull the
real transitive include directories and headers out of Bazel's own compilation-context
bookkeeping.
"""

load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

def _root_dictionary_impl(ctx):
    cc_infos = [dep[CcInfo] for dep in ctx.attr.deps]
    compilation_context = cc_common.merge_cc_infos(cc_infos = cc_infos).compilation_context

    out_cxx = ctx.actions.declare_file(ctx.attr.name + ".cxx")
    out_pcm = ctx.actions.declare_file(ctx.attr.name + "_rdict.pcm")

    args = ctx.actions.args()
    args.add("-f", out_cxx)
    args.add("-inlineInputHeader")

    # quote_includes covers the module's own directory (where the LinkDef/dict headers live);
    # includes/system_includes cover everything pulled in transitively via deps (Nymph, Scarab,
    # rapidjson, yaml-cpp, Boost, FFTW).
    for d in (compilation_context.quote_includes.to_list() +
              compilation_context.includes.to_list() +
              compilation_context.system_includes.to_list()):
        args.add("-I" + d)

    # Pass basenames, not full paths: with -inlineInputHeader, rootcling embeds whatever
    # string is given here literally as the #include target in the generated .cxx. A full
    # execroot-relative path (e.g. "external/+non_bazel_deps+cicada/Library/Foo.hh") doesn't
    # resolve when that .cxx is later compiled from a different location in bazel-out. A bare
    # basename does resolve, the same way CMake's ROOT_GENERATE_DICTIONARY normally invokes
    # rootcling - both rootcling's own header lookup *and* the later real compile rely on the
    # -I flags above (both already include this module's own directory via quote_includes),
    # not on any path baked into the argument itself.
    args.add_all([h.basename for h in ctx.files.headers])
    args.add(ctx.file.linkdef)

    ctx.actions.run(
        executable = ctx.file._rootcling,
        arguments = [args],
        inputs = depset(
            ctx.files.headers + [ctx.file.linkdef, ctx.file._rootcling],
            transitive = [compilation_context.headers],
        ),
        outputs = [out_cxx, out_pcm],
        mnemonic = "RootCling",
        # rootcling writes both the .cxx and the sibling _rdict.pcm next to each other based on
        # the -f path; declaring both as outs above tells Bazel to expect exactly that.
        env = {"ROOT_INCLUDE_PATH": ":".join(compilation_context.system_includes.to_list())},
    )

    return [
        DefaultInfo(files = depset([out_cxx, out_pcm])),
        OutputGroupInfo(
            cxx = depset([out_cxx]),
            pcm = depset([out_pcm]),
        ),
    ]

_root_dictionary_gen = rule(
    implementation = _root_dictionary_impl,
    attrs = {
        "headers": attr.label_list(allow_files = [".hh", ".h"], mandatory = True),
        "linkdef": attr.label(allow_single_file = True, mandatory = True),
        # The cc_library(s) whose transitive include paths/headers rootcling needs to see -
        # normally just the owning module's own cc_library plus its direct deps.
        "deps": attr.label_list(providers = [CcInfo], mandatory = True),
        # allow_single_file (not executable=True): @homebrew//:rootcling is a plain source
        # file (symlinked in via exports_files()), not a build rule with a FilesToRunProvider
        # - executable=True requires the latter and fails with "is misplaced here" otherwise.
        # ctx.actions.run() accepts a File directly for `executable`, so this works fine.
        "_rootcling": attr.label(
            default = "@homebrew//:rootcling",
            allow_single_file = True,
            cfg = "exec",
        ),
    },
)

def root_dictionary(name, headers, linkdef, deps):
    """Convenience wrapper: generates <name>.cxx and <name>_rdict.pcm.

    Add "<name>.cxx" to the owning cc_library's srcs (via `:<name>` won't work directly since
    this produces two outputs - use `filegroup` below, or reference `<name>_gen` and pick the
    cxx/pcm OutputGroups explicitly).
    """
    _root_dictionary_gen(
        name = name + "_gen",
        headers = headers,
        linkdef = linkdef,
        deps = deps,
    )

    native.filegroup(
        name = name + "_cxx",
        srcs = [":" + name + "_gen"],
        output_group = "cxx",
    )

    native.filegroup(
        name = name + "_pcm",
        srcs = [":" + name + "_gen"],
        output_group = "pcm",
    )
