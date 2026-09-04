"""Fetches the git-submodule dependencies that have no native Bazel support of their own.

Each of these is pulled at the exact commit recorded in the original katydid checkout's
`git submodule status` (branch feature/FreqDomainInput):

    329b058736771038c150933bc275448ca5f24245  Cicada   (v1.3.2-1-g329b058)
    f3697b89f345894bc20c2c2d07fd553aa3b22de2  Nymph    (v1.4.7)
    ef2af248c5db7c92c84952a57759ba0f145f6cd4  Scarab   (pinned by both Nymph and Cicada - identical
                                                         commit in both, so no version conflict)
    5de06bfa37495b529dc00139f1b138a526fff27a  rapidjson (pinned by Scarab)
    3757b2023b71d183a341677feee693c71c2e0766  yaml-cpp  (pinned by Scarab)

Source/Time/Monarch is NOT fetched: Katydid_USE_MONARCH defaults OFF in CMakeLists.txt and
nothing outside its own #ifdef touches it. Add it here if that ever changes.

Cicada is not yet wired in - it needs the rootcling/ROOT_GENERATE_DICTIONARY genrule support
(root_dictionary.bzl), which hasn't been built yet. See NOTES.md.

We fetch rapidjson and yaml-cpp as their own top-level Bazel repos rather than relying on the
copies nested inside Scarab's own submodule checkout - this avoids needing
`git_repository(init_submodules = True)` (recursive submodule fetch inside a fetched repo,
which is flaky) and keeps each dependency's pin independently visible here.
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
        commit = "5de06bfa37495b529dc00139f1b138a526fff27a",
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
