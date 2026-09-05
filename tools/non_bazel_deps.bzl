"""Fetches Katydid's own bundled dependencies that have no native Bazel support of their own.

Each is pulled as a pinned git commit, matching the commit that the project's canonical CMake
build (via `git submodule status`) uses:

    Cicada     https://github.com/Helium6CRES/cicada.git
    Nymph      https://github.com/project8/nymph.git
    Scarab     https://github.com/project8/scarab.git      (pinned identically by both Nymph
                                                              and Cicada - no version conflict)
    rapidjson  https://github.com/miloyip/rapidjson.git     (pinned by Scarab)
    yaml-cpp   https://github.com/jbeder/yaml-cpp.git       (pinned by Scarab)

If Katydid's submodule pins change (e.g. moving to a newer Nymph release), update the `commit`
value below to match - there is no automatic sync between this file and `.gitmodules`.

`Source/Time/Monarch` is intentionally not fetched here: `Katydid_USE_MONARCH` defaults off in
the CMake build, and nothing outside its own `#ifdef` guard references it.

rapidjson and yaml-cpp are fetched as their own top-level repositories, rather than relying on
the copies nested inside Scarab's own submodule checkout. This avoids needing
`git_repository(init_submodules = True)` (a recursive submodule fetch inside an already-fetched
repository, which is unreliable) and keeps each dependency's pin independently visible here.
"""

load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository")

def _non_bazel_deps_impl(_module_ctx):
    git_repository(
        name = "scarab",
        remote = "https://github.com/project8/scarab.git",
        commit = "ef2af248c5db7c92c84952a57759ba0f145f6cd4",
        build_file = "//third_party/scarab:BUILD.scarab.bazel",
    )

    git_repository(
        name = "nymph",
        remote = "https://github.com/project8/nymph.git",
        commit = "f3697b89f345894bc20c2c2d07fd553aa3b22de2",
        build_file = "//third_party/nymph:BUILD.nymph.bazel",
    )

    git_repository(
        name = "rapidjson",
        remote = "https://github.com/miloyip/rapidjson.git",
        commit = "24b5e7a8b27f42fa16b96fc70aade9106cf7102f",
        build_file = "//third_party/rapidjson:BUILD.rapidjson.bazel",
    )

    git_repository(
        name = "yaml_cpp",
        remote = "https://github.com/jbeder/yaml-cpp.git",
        commit = "3757b2023b71d183a341677feee693c71c2e0766",
        build_file = "//third_party/yaml_cpp:BUILD.yaml_cpp.bazel",
    )

    git_repository(
        name = "cicada",
        remote = "https://github.com/Helium6CRES/cicada.git",
        commit = "329b058736771038c150933bc275448ca5f24245",
        build_file = "//third_party/cicada:BUILD.cicada.bazel",
    )

non_bazel_deps = module_extension(implementation = _non_bazel_deps_impl)
