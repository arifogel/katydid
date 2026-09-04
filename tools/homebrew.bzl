"""Wraps Homebrew-installed libraries (Boost, FFTW today; ROOT/MatIO in a later step) as
cc_library targets, by shelling out to `brew --prefix <formula>` when the repo is fetched.

This is a deliberate trade: these libraries are NOT built hermetically by Bazel, and the exact
version you get depends on whatever `brew install <formula>` last put on your machine. In
exchange, there's zero manual configure step, and - critically for the ROOT step still to come -
we sidestep ever needing to compile ROOT from source inside the Bazel graph, which would be slow
and is not something the Bazel ecosystem supports out of the box.

If true hermeticity is wanted later: pin exact Homebrew formula versions (`brew install
boost@1.83`-style), or switch to vendored prebuilt archives fetched via http_archive.

Usage from a BUILD file: deps = ["@homebrew//:boost", "@homebrew//:fftw"]
"""

_FORMULAE = {
    "boost": {
        # header-only usage needs no libs, but Nymph/Scarab/Katydid link these components
        "libs": [
            "boost_filesystem",
            "boost_system",
            "boost_thread",
            "boost_date_time",
            "boost_program_options",
        ],
    },
    "fftw": {
        "libs": ["fftw3"],
    },
}

def _homebrew_repo_impl(repository_ctx):
    brew = repository_ctx.which("brew")
    if not brew:
        fail(
            "`brew` was not found on PATH. Install Homebrew (https://brew.sh), then " +
            "`brew install boost fftw`, or adjust tools/homebrew.bzl if your libraries " +
            "live somewhere else (e.g. MacPorts, conda).",
        )

    build_file_parts = [
        'load("@rules_cc//cc:cc_library.bzl", "cc_library")',
        'package(default_visibility = ["//visibility:public"])',
    ]
    for formula, info in _FORMULAE.items():
        result = repository_ctx.execute([brew, "--prefix", formula])
        if result.return_code != 0:
            fail(
                "`brew --prefix {f}` failed - run `brew install {f}`.\n{err}".format(
                    f = formula,
                    err = result.stderr,
                ),
            )
        prefix = result.stdout.strip()

        # Symlink brew's include dir into this repo so `hdrs = glob(...)` has real files to see -
        # brew's prefix lives outside the workspace/output tree and Bazel can't glob into it directly.
        repository_ctx.symlink(prefix + "/include", formula + "/include")

        linkopts = ["-L" + prefix + "/lib"] + ["-l" + lib for lib in info["libs"]]

        build_file_parts.append("""
cc_library(
    name = "{formula}",
    hdrs = glob(["{formula}/include/**"]),
    includes = ["{formula}/include"],
    linkopts = {linkopts},
)
""".format(formula = formula, linkopts = repr(linkopts)))

    repository_ctx.file("BUILD.bazel", "\n".join(build_file_parts))

_homebrew_repo = repository_rule(
    implementation = _homebrew_repo_impl,
    local = True,  # re-evaluate every build so `brew upgrade`/`brew install` is picked up
)

def _homebrew_deps_impl(_module_ctx):
    _homebrew_repo(name = "homebrew")

homebrew_deps = module_extension(implementation = _homebrew_deps_impl)
