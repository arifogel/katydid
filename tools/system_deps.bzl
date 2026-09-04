"""Wraps system-provided libraries (Boost, FFTW, MatIO, ROOT) as cc_library targets - via
Homebrew on macOS, via apt on Linux. ROOT is handled the same way on both: neither path
assumes Homebrew or apt actually provides it (apt's ROOT packaging is inconsistent across
Ubuntu releases, and building ROOT from source is squarely "unreasonable to build from
source" territory) - instead this just requires `root-config` to already be on PATH,
however it got there (a Homebrew symlink, or a prebuilt tarball from root.cern extracted
somewhere like /opt/root with its bin/ added to PATH - both work identically here, since
root-config is ROOT's own official query tool regardless of how it was installed).

This is a deliberate trade: none of this is built hermetically by Bazel, and the exact
version you get depends on what's already on the machine. In exchange, there's no need to
compile ROOT from source inside the Bazel graph (slow, and not something the Bazel
ecosystem supports out of the box), and on Linux, apt-installed Boost/FFTW/MatIO need no
explicit discovery at all - apt installs into the compiler/linker's default search paths,
unlike Homebrew, which deliberately keeps things out of the way.

Usage from a BUILD file: deps = ["@homebrew//:boost", "@homebrew//:fftw"]
(the repo is still named "homebrew" even though it also covers apt on Linux now - renaming
the exposed repo name would mean touching every BUILD file that references it, for no real
benefit; only this file's own name changed, from tools/homebrew.bzl.)
"""

_MAC_FORMULAE = {
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

# Linux: apt-installed Boost/FFTW/MatIO need no -I/-L at all (default search paths already
# cover them) - just -l flags, after checking the right -dev packages are actually installed.
# Package names/versions confirmed against Ubuntu 24.04 (noble)'s package index directly,
# not assumed - matio's shared lib is libmatio13, but libmatio-dev provides the unversioned
# libmatio.so symlink needed for a plain -lmatio to resolve, same pattern as most -dev packages.
_LINUX_APT_LIBS = {
    "boost": {
        "apt_packages": [
            "libboost-filesystem-dev",
            "libboost-thread-dev",
            "libboost-date-time-dev",
            "libboost-program-options-dev",
        ],
        "libs": ["boost_filesystem", "boost_thread", "boost_date_time", "boost_program_options"],
    },
    "fftw": {
        "apt_packages": ["libfftw3-dev"],
        "libs": ["fftw3"],
        "defines": ["FFTW_FOUND"],
    },
    "matio": {
        "apt_packages": ["libmatio-dev"],
        "libs": ["matio"],
    },
}

def _is_macos(repository_ctx):
    return repository_ctx.os.name.lower().startswith("mac")

def _root_config_not_found_error():
    return (
        "`root-config` was not found on PATH. Install ROOT and make sure its bin/ directory " +
        "is on PATH:\n" +
        "  macOS:  `brew install root` (Homebrew symlinks root-config onto PATH automatically)\n" +
        "  Linux:  download a prebuilt binary from https://root.cern/install/, extract it " +
        "somewhere (e.g. /opt/root), and add its bin/ directory to PATH (building ROOT from " +
        "source is not recommended - it's a large, slow build).\n" +
        "Or adjust tools/system_deps.bzl if ROOT lives somewhere else."
    )

def _homebrew_repo_impl(repository_ctx):
    is_macos = _is_macos(repository_ctx)

    build_file_parts = ['load("@rules_cc//cc:cc_library.bzl", "cc_library")']
    build_file_parts.append('package(default_visibility = ["//visibility:public"])')

    # --- ROOT: OS-agnostic. Uses root-config, ROOT's own official query tool, rather than
    # guessing an install layout (which differs between Homebrew's Cellar, a root.cern tarball
    # extracted to /opt/root, LCG, conda...). Every ROOT install ships root-config for exactly
    # this reason, regardless of how it got onto the machine.
    root_config = repository_ctx.which("root-config")
    if not root_config:
        fail(_root_config_not_found_error())

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

    # --- Boost / FFTW / MatIO: genuinely different discovery per OS, not just a different
    # formula name. Homebrew deliberately keeps things out of default search paths (needs
    # explicit -I/-L, found via `brew --prefix`); apt installs into them (needs neither).
    if is_macos:
        brew = repository_ctx.which("brew")
        if not brew:
            fail(
                "`brew` was not found on PATH. Install Homebrew (https://brew.sh), then " +
                "`brew install boost fftw libmatio`, or adjust tools/system_deps.bzl if your " +
                "libraries live somewhere else (e.g. MacPorts, conda).",
            )

        for formula, info in _MAC_FORMULAE.items():
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

            # Symlink brew's include dir into this repo so `hdrs = glob(...)` has real files to
            # see - brew's prefix lives outside the workspace/output tree, Bazel can't glob into
            # it directly.
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

    else:
        for formula, info in _LINUX_APT_LIBS.items():
            missing = []
            for pkg in info["apt_packages"]:
                result = repository_ctx.execute(["dpkg", "-s", pkg])
                if result.return_code != 0:
                    missing.append(pkg)
            if missing:
                fail(
                    "Missing apt package(s) for {formula}: {missing}\nRun:\n  sudo apt install {pkgs}".format(
                        formula = formula,
                        missing = ", ".join(missing),
                        pkgs = " ".join(info["apt_packages"]),
                    ),
                )

            linkopts = ["-l" + lib for lib in info["libs"]]

            # No hdrs/includes: apt already put the headers on the compiler's default system
            # include path (/usr/include), which Bazel's auto-configured C++ toolchain always
            # allows inside the sandbox - the same mechanism that makes <vector>/<stdio.h> work
            # without declaring them as hdrs on any target.
            build_file_parts.append("""
cc_library(
    name = "{formula}",
    defines = {defines},
    linkopts = {linkopts},
)
""".format(formula = formula, defines = repr(info.get("defines", [])), linkopts = repr(linkopts)))

    repository_ctx.file("BUILD.bazel", "\n".join(build_file_parts))

_homebrew_repo = repository_rule(
    implementation = _homebrew_repo_impl,
    local = True,  # re-evaluate every build so `brew upgrade`/`apt install`/etc. is picked up
)

def _homebrew_deps_impl(_module_ctx):
    _homebrew_repo(name = "homebrew")

homebrew_deps = module_extension(implementation = _homebrew_deps_impl)
