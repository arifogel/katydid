"""Provides Boost, FFTW, and MatIO for macOS via Homebrew (tools/brew.bzl), exposed as
@macos_libs - unpinned, using whatever version `brew install` currently resolves to (see
BUILDING.md).

cc_import, not cc_library, for the same reason as tools/ubuntu_libs.bzl/tools/almalinux_libs.bzl
(see either's module docstring): it's exempt from cc_shared_library's "linked statically but
not exported" check for a library reachable from more than one cc_shared_library's deps (e.g.
Boost, needed by both katydid_utility and nymph) - bazelbuild/bazel#19920.

Nothing should reference this repo directly - go through @binary_deps instead (see
tools/binary_deps.bzl), which resolves to whichever platform repo is actually live on the
current host, with no select()/config_setting/flag anywhere.
"""

load(":brew.bzl", "brew_cc_import_snippet", "brew_require")

_FORMULAE = {
    "boost": {
        # Nymph/Scarab/Katydid link these specific components, not just Boost's header-only
        # parts. boost_system deliberately omitted: header-only since 1.69, and Boost 1.89
        # removed the compiled stub library entirely - linking -lboost_system fails on any
        # current Homebrew Boost.
        "libs": [
            "boost_filesystem",
            "boost_thread",
            "boost_date_time",
            "boost_program_options",
        ],
    },
    "fftw": {
        "libs": ["fftw3"],
        # Katydid's code checks #ifdef FFTW_FOUND (e.g. Data/Time/KTPhysicalArrayFFTW.hh) to
        # choose between real fftw3.h and a bundled stand-in header - matches CMake's
        # add_definitions(-DFFTW_FOUND).
        "defines": ["FFTW_FOUND"],
    },
    # Homebrew's formula for MatIO is "libmatio", not "matio" - keep the exposed target name
    # ("matio") matching what Katydid's CMake calls it, separate from the brew formula name.
    "matio": {
        "brew_formula": "libmatio",
        "libs": ["matio"],
    },
}

def _macos_libs_repo_impl(repository_ctx):
    brew = brew_require(repository_ctx)

    build_file_parts = [
        'load("@rules_cc//cc:cc_import.bzl", "cc_import")',
        'package(default_visibility = ["//visibility:public"])',
    ]
    for formula, info in _FORMULAE.items():
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
