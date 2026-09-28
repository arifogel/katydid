"""Provides Boost, FFTW, and MatIO for macOS via Homebrew, exposed as @macos_libs - unpinned,
using whatever version `brew install` currently resolves to (see BUILDING.md).

cc_import, not cc_library: it's exempt from cc_shared_library's "linked statically but not
exported" check for a library reachable from more than one cc_shared_library's deps (e.g.
Boost, needed by both katydid_utility and nymph) - bazelbuild/bazel#19920.

Nothing should reference this repo directly - resolution to whichever platform repo is
actually live on the current host happens with no select()/config_setting/flag anywhere.
"""

load(":brew.bzl", "MAC_BREW_FORMULAE", "brew_cc_import_snippet", "brew_require")

def _macos_libs_repo_impl(repository_ctx):
    brew = brew_require(repository_ctx)

    build_file_parts = [
        'load("@rules_cc//cc:cc_import.bzl", "cc_import")',
        'package(default_visibility = ["//visibility:public"])',
    ]
    for formula, info in MAC_BREW_FORMULAE.items():
        parts, _lib_dir = brew_cc_import_snippet(
            repository_ctx,
            brew = brew,
            dest_prefix = formula,
            brew_formula = info.get("brew_formula", formula),
            libs = info["libs"],
            defines = info.get("defines", []),
        )
        build_file_parts.extend(parts)

    repository_ctx.file("BUILD.bazel", "\n".join(build_file_parts))

_macos_libs_repo = repository_rule(
    implementation = _macos_libs_repo_impl,
    local = True,  # re-evaluate every build so `brew upgrade`/install is picked up
)

def _macos_libs_impl(_module_ctx):
    _macos_libs_repo(name = "macos_libs")

macos_libs = module_extension(implementation = _macos_libs_impl)
