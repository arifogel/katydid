"""Wraps Homebrew-installed libraries (Boost, FFTW, MatIO, ROOT) as cc_library targets, by
shelling out to `brew --prefix <formula>` (or, for ROOT, `root-config`) when the repo is fetched.

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
        # header-only usage needs no libs, but Nymph/Scarab/Katydid link these components.
        # boost_system deliberately NOT listed: Boost.System has been header-only since 1.69,
        # and Boost 1.89 (2025) removed the compiled stub library entirely - linking -lboost_system
        # now fails outright ("library not found") on any current Homebrew Boost.
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
        # choose between real fftw3.h and a bundled stand-in header. Defining it here, once,
        # propagates transitively to every target that depends on @homebrew//:fftw (directly
        # or via Utility) - same as CMake's `add_definitions(-DFFTW_FOUND)` did project-wide.
        "defines": ["FFTW_FOUND"],
    },
    # Homebrew's formula for MatIO is "libmatio", not "matio" - keep the exposed target name
    # ("matio") matching what Katydid's CMake calls it, separate from the brew formula name.
    "matio": {
        "brew_formula": "libmatio",
        "libs": ["matio"],
    },
}

def _homebrew_repo_impl(repository_ctx):
    brew = repository_ctx.which("brew")
    if not brew:
        fail(
            "`brew` was not found on PATH. Install Homebrew (https://brew.sh), then " +
            "`brew install boost fftw libmatio root`, or adjust tools/homebrew.bzl if your " +
            "libraries live somewhere else (e.g. MacPorts, conda).",
        )

    build_file_parts = ['load("@rules_cc//cc:cc_library.bzl", "cc_library")']
    build_file_parts.append('package(default_visibility = ["//visibility:public"])')

    # --- ROOT: uses root-config, ROOT's own official query tool, rather than guessing
    # Homebrew's Cellar layout (which has changed shape across ROOT versions before). Every
    # ROOT install - Homebrew, source build, LCG, conda - ships root-config for exactly this.
    root_config = repository_ctx.which("root-config")
    if not root_config:
        fail(
            "`root-config` was not found on PATH. Install ROOT (`brew install root`) and make " +
            "sure its bin/ directory is on PATH (Homebrew normally symlinks this for you), or " +
            "adjust tools/homebrew.bzl if ROOT lives somewhere else.",
        )

    root_incdir = repository_ctx.execute([root_config, "--incdir"]).stdout.strip()
    root_libdir = repository_ctx.execute([root_config, "--libdir"]).stdout.strip()
    root_bindir = repository_ctx.execute([root_config, "--bindir"]).stdout.strip()

    # Base libs (Core, RIO, Net, Hist, Graf, Tree, ... ) from root-config, plus the extra
    # COMPONENTS Katydid's CMakeLists.txt explicitly requests via
    # find_package(ROOT 6.00 COMPONENTS Gui Spectrum TMVA) - root-config --libs alone doesn't
    # include those, they have to be added by hand the same way CMake's find_package would.
    root_base_libs_result = repository_ctx.execute([root_config, "--libs"])
    if root_base_libs_result.return_code != 0:
        fail("`root-config --libs` failed:\n" + root_base_libs_result.stderr)
    root_extra_component_libs = ["-lGui", "-lSpectrum", "-lTMVA"]

    repository_ctx.symlink(root_incdir, "root/include")

    root_base_libs = [x for x in root_base_libs_result.stdout.strip().split(" ") if x]
    root_linkopts = (
        root_base_libs +
        root_extra_component_libs +
        ["-Wl,-rpath," + root_libdir]  # ROOT dlopens plugin libs at runtime; needs rpath, not just -L
    )

    build_file_parts.append("""
cc_library(
    name = "root",
    hdrs = glob(["root/include/**"], allow_empty = True),
    includes = ["root/include"],
    # Propagates to every transitive dependent, same reasoning as FFTW_FOUND below - Katydid's
    # code checks #ifdef ROOT_FOUND throughout, matching CMake's `add_definitions(-DROOT_FOUND)`.
    defines = ["ROOT_FOUND"],
    linkopts = {linkopts},
)
""".format(linkopts = repr(root_linkopts)))

    # rootcling lives in root-config's bindir; exposed as a plain file for root_dictionary.bzl
    # to depend on as an executable.
    repository_ctx.symlink(root_bindir + "/rootcling", "rootcling")
    build_file_parts.append("""
exports_files(["rootcling"])
""")

    for formula, info in _FORMULAE.items():
        brew_formula = info.get("brew_formula", formula)
        result = repository_ctx.execute([brew, "--prefix", brew_formula])
        if result.return_code != 0:
            fail(
                "`brew --prefix {f}` failed - run `brew install {f}`.\n{err}".format(
                    f = brew_formula,
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
    hdrs = glob(["{formula}/include/**"], allow_empty = True),
    includes = ["{formula}/include"],
    defines = {defines},
    linkopts = {linkopts},
)
""".format(formula = formula, defines = repr(info.get("defines", [])), linkopts = repr(linkopts)))

    repository_ctx.file("BUILD.bazel", "\n".join(build_file_parts))

_homebrew_repo = repository_rule(
    implementation = _homebrew_repo_impl,
    local = True,  # re-evaluate every build so `brew upgrade`/`brew install` is picked up
)

def _homebrew_deps_impl(_module_ctx):
    _homebrew_repo(name = "homebrew")

homebrew_deps = module_extension(implementation = _homebrew_deps_impl)
