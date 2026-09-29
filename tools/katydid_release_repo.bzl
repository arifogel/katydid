"""Exposes //:katydid_release's own tarball as a real Bazel repo, @katydid_release, so a
consumer outside this repo can depend on a built, portable Katydid the way it depends on any
other hermetic external repo - never on the tarball itself.

@katydid_release//:katydid is an sh_binary wrapping the tarball's bin/Katydid, with the rest of
the tarball (bin/Katydid_bin, lib/, root/, include/) as its data. Because these land as plain,
repository-relative data files - not through Bazel's solib-farm symlink indirection a linked
cc_import/cc_binary dependency would go through - any tool that materializes a consumer's own
runfiles into a real, standalone copy (a release/packaging step, for instance) carries this
whole tree along intact, and bin/Katydid's own $(dirname "$0")-relative lookups for ../lib and
../root keep resolving correctly wherever that copy ends up.
"""

def _katydid_release_repo_impl(repository_ctx):
    repository_ctx.extract(repository_ctx.path(repository_ctx.attr.release_tar))

    repository_ctx.file("BUILD.bazel", """\
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

package(default_visibility = ["//visibility:public"])

sh_binary(
    name = "katydid",
    srcs = ["bin/Katydid"],
    data = glob(["**"], exclude = ["bin/Katydid", "BUILD.bazel"]),
)
""")

_katydid_release_repo = repository_rule(
    implementation = _katydid_release_repo_impl,
    attrs = {
        "release_tar": attr.label(
            default = Label("//:katydid_release"),
            allow_single_file = True,
            doc = "The //:katydid_release tarball to unpack into this repo.",
        ),
    },
)

def _katydid_release_impl(_module_ctx):
    _katydid_release_repo(name = "katydid_release")

katydid_release = module_extension(implementation = _katydid_release_impl)
