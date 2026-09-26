"""Wraps system-provided libraries (Boost, FFTW, MatIO), exposed as @system_libs - via
Homebrew on macOS, via apt or dnf on Linux (whichever is actually on PATH - not a hardcoded
distro list, so this doesn't need editing again for the next Linux flavor that shows up).

ROOT's fetch/discovery lives in tools/root.bzl, fully independent of this file: its module
extension (root_deps) registers @root on its own, and this file's system_deps extension knows
nothing about it.

On every OS, Boost/FFTW/MatIO are exposed as real cc_import targets pointing at the
already-installed .so/.dylib file for each library component (located via known apt/dnf paths
on Linux, via `brew --prefix` on macOS), not a cc_library with a fake, empty placeholder
source file. These libraries are never compiled by Bazel; cc_import represents that directly.
This also fixes cc_shared_library's "linked statically but not exported" error for a library
reachable from more than one cc_shared_library's deps (e.g. Boost, needed by both
katydid_utility and nymph): cc_import is exempt from that check, cc_library is not (confirmed
empirically, even for a header-only cc_library with zero srcs - bazelbuild/bazel#19920), and
Bazel's own source doesn't document why. If a future Bazel version's behavior here changes,
tags = ["LINKABLE_MORE_THAN_ONCE"] on the per-component cc_import targets below is the
fallback - safe here specifically because a cc_import wrapping an existing system .so/.dylib
has no compiled code of its own to duplicate, unlike a library actually compiled from source
(e.g. @yaml_cpp, which needs its own real cc_shared_library instead, since a tag there would
paper over genuinely duplicated code).

Boost/FFTW/MatIO are discovered from what's already on the machine (Homebrew, apt, dnf) rather
than fetched hermetically, so the exact version you get depends on what's already installed.
The two OSes differ only in how the library is located, not in what kind of target represents
it once found: apt/dnf-installed Boost/FFTW/MatIO need no explicit -I (their headers land on
the compiler's default system include path); Homebrew keeps things out of the way, so macOS
needs `brew --prefix` plus explicit hdrs/includes on the aggregating cc_import below.

Usage from a BUILD file: deps = ["@system_libs//:boost", "@system_libs//:fftw"]
"""

_MAC_FORMULAE = {
    "boost": {
        # Nymph/Scarab/Katydid link these specific components, not just Boost's header-only
        # parts. boost_system deliberately NOT listed: Boost.System has been header-only since
        # 1.69, and Boost 1.89 (2025) removed the compiled stub library entirely - linking
        # -lboost_system now fails outright on any current Homebrew Boost.
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
        # propagates transitively to every target that depends on @system_libs//:fftw (directly
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

# Linux: apt-installed Boost/FFTW/MatIO need no -I/-L (default search paths cover them) - just
# -l flags. Package names/versions confirmed against Ubuntu 24.04 (noble)'s package index -
# matio's shared lib is libmatio13, but libmatio-dev provides the unversioned libmatio.so
# symlink a plain -lmatio needs to resolve, same pattern as most -dev packages.
_LINUX_APT_LIBS = {
    "boost": {
        "packages": [
            "libboost-filesystem-dev",
            "libboost-thread-dev",
            "libboost-date-time-dev",
            "libboost-program-options-dev",
        ],
        "libs": ["boost_filesystem", "boost_thread", "boost_date_time", "boost_program_options"],
    },
    "fftw": {
        "packages": ["libfftw3-dev"],
        "libs": ["fftw3"],
        "defines": ["FFTW_FOUND"],
    },
    "matio": {
        "packages": ["libmatio-dev"],
        "libs": ["matio"],
    },
}

# AlmaLinux 9 / RHEL 9 family (dnf). Same "no -I/-L needed" reasoning as apt: dnf also installs
# into the compiler/linker's default search paths. Package names confirmed against the
# AlmaLinux/EPEL package index: boost-devel/fftw-devel live in AlmaLinux 9's AppStream repo;
# matio-devel specifically needs EPEL (`dnf install epel-release`) - it isn't in AppStream or CRB.
_LINUX_DNF_LIBS = {
    "boost": {
        "packages": ["boost-devel"],
        "libs": ["boost_filesystem", "boost_thread", "boost_date_time", "boost_program_options"],
    },
    "fftw": {
        "packages": ["fftw-devel"],
        "libs": ["fftw3"],
        "defines": ["FFTW_FOUND"],
    },
    "matio": {
        "packages": ["matio-devel"],
        "libs": ["matio"],
    },
}

# Checked by looking for the actual header each library installs, not by asking the package
# manager whether a package name is "installed" (`dpkg -s` / `rpm -q`): some package managers
# use "transitional" wrapper packages for versioned libraries (e.g. Ubuntu's
# libboost-filesystem-dev depends on the real libboost-filesystem1.83-dev), and some CI caching
# doesn't reliably register these wrapper packages even when the files are actually present.
# Checking for the header sidesteps this and is identical logic on both apt and dnf.
_LINUX_HEADER_CHECK = {
    "boost": "usr/include/boost/version.hpp",
    "fftw": "usr/include/fftw3.h",
    "matio": "usr/include/matio.h",
}

def _is_macos(repository_ctx):
    return repository_ctx.os.name.lower().startswith("mac")

# Distinguishes apt-based vs dnf-based Linux by which package manager binary is actually on
# PATH, rather than parsing /etc/os-release or hardcoding a list of distro names - robust to
# whatever distro shows up next without needing this file edited again.
def _linux_pkg_manager(repository_ctx):
    if repository_ctx.which("apt-get"):
        return "apt", _LINUX_APT_LIBS
    if repository_ctx.which("dnf"):
        return "dnf", _LINUX_DNF_LIBS
    fail(
        "Could not find `apt-get` or `dnf` on PATH - tools/system_deps.bzl doesn't know how " +
        "to install Boost/FFTW/MatIO on this Linux distro yet. Add a branch for it (see the " +
        "existing apt/dnf ones for the pattern).",
    )

def _check_header_or_fail(repository_ctx, formula, header, packages, install_hint):
    if not repository_ctx.path("/" + header).exists:
        fail("Missing header /{header} (needed for {formula}) - looks like it isn't installed.\nRun:\n  {hint}".format(
            header = header,
            formula = formula,
            hint = install_hint.format(pkgs = " ".join(packages)),
        ))

# Locates the real, already-installed .so file: apt (Debian/Ubuntu multiarch) and dnf
# (RHEL-family lib64) put it in different places, and cc_import needs a concrete file path,
# not a linker search hint.
def _find_shared_lib_or_fail(repository_ctx, libname, packages, install_hint):
    candidate_paths = [
        "/usr/lib/x86_64-linux-gnu/lib{}.so".format(libname),  # apt (Debian/Ubuntu multiarch)
        "/usr/lib64/lib{}.so".format(libname),  # dnf (RHEL-family)
        "/usr/lib/lib{}.so".format(libname),  # less common, but seen on some distros
    ]
    for path in candidate_paths:
        if repository_ctx.path(path).exists:
            return path
    fail(
        "Could not find lib{lib}.so in any known location ({paths}) - looks like it isn't " +
        "installed.\nRun:\n  {hint}".format(
            lib = libname,
            paths = ", ".join(candidate_paths),
            hint = install_hint.format(pkgs = " ".join(packages)),
        ),
    )

# Locates the real, already-installed .dylib file under a formula's `brew --prefix` - unlike
# Linux's apt/dnf, Homebrew always puts it at exactly one place, so there's a single candidate
# to check rather than a list.
def _find_mac_dylib_or_fail(repository_ctx, prefix, libname, brew_formula):
    path = "{}/lib/lib{}.dylib".format(prefix, libname)
    if repository_ctx.path(path).exists:
        return path
    fail(
        "Could not find {path} - looks like `brew install {f}` didn't provide it, or " +
        "Homebrew's layout for this formula has changed.".format(path = path, f = brew_formula),
    )

def _system_libs_repo_impl(repository_ctx):
    is_macos = _is_macos(repository_ctx)

    build_file_parts = [
        'load("@rules_cc//cc:cc_import.bzl", "cc_import")',
    ]
    build_file_parts.append('package(default_visibility = ["//visibility:public"])')

    # Every macOS formula's absolute <prefix>/lib directory (empty on Linux) - written out below
    # as its own .bzl file so release_binary.bzl/harvest_runtime_libs.bzl can bake these in as
    # extra RPATH entries on the release archive (see harvest_runtime_libs.bzl's docstring for
    # why the release archive needs this at all).
    mac_lib_dirs = []

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
            mac_lib_dirs.append(prefix + "/lib")

            # Symlink brew's include dir into this repo so `hdrs = glob(...)` has real files to
            # see - brew's prefix lives outside the workspace/output tree, Bazel can't glob into
            # it directly.
            repository_ctx.symlink(prefix + "/include", formula + "/include")

            # Real cc_import per library component, matching Linux - see this file's top
            # comment for why (not a cc_library + linkopts).
            component_import_labels = []
            for lib in info["libs"]:
                dylib_path = _find_mac_dylib_or_fail(repository_ctx, prefix, lib, brew_formula)
                symlink_name = "{formula}/lib{lib}.dylib".format(formula = formula, lib = lib)
                repository_ctx.symlink(dylib_path, symlink_name)

                import_name = "_{formula}_{lib}_import".format(formula = formula, lib = lib)
                component_import_labels.append(":" + import_name)
                build_file_parts.append("""
cc_import(
    name = "{import_name}",
    shared_library = "{symlink_name}",
)
""".format(import_name = import_name, symlink_name = symlink_name))

            # hdrs/includes live on this aggregating target since Homebrew's include/ isn't on
            # the default system include path (unlike apt/dnf's, on Linux).
            build_file_parts.append("""
cc_import(
    name = "{formula}",
    hdrs = glob(["{formula}/include/**"], allow_empty = True),
    includes = ["{formula}/include"],
    defines = {defines},
    deps = {component_import_labels},
)
""".format(
                formula = formula,
                defines = repr(info.get("defines", [])),
                component_import_labels = repr(component_import_labels),
            ))

    else:
        pkg_manager, linux_libs = _linux_pkg_manager(repository_ctx)
        install_hint = "sudo apt install {pkgs}" if pkg_manager == "apt" else "sudo dnf install {pkgs}"

        for formula, info in linux_libs.items():
            _check_header_or_fail(
                repository_ctx,
                formula,
                _LINUX_HEADER_CHECK[formula],
                info["packages"],
                install_hint,
            )

            # Real cc_import per library component - see this file's top comment for why.
            #
            # Symlinked into this repository first: cc_import's shared_library attribute takes
            # a label (a file within this repository), not an arbitrary absolute path.
            component_import_labels = []
            for lib in info["libs"]:
                so_path = _find_shared_lib_or_fail(repository_ctx, lib, info["packages"], install_hint)
                symlink_name = "{formula}/lib{lib}.so".format(formula = formula, lib = lib)
                repository_ctx.symlink(so_path, symlink_name)

                import_name = "_{formula}_{lib}_import".format(formula = formula, lib = lib)
                component_import_labels.append(":" + import_name)
                build_file_parts.append("""
cc_import(
    name = "{import_name}",
    shared_library = "{symlink_name}",
)
""".format(import_name = import_name, symlink_name = symlink_name))

            # No hdrs/includes: apt/dnf already put the headers on the compiler's default
            # system include path (/usr/include).
            #
            # This aggregating target is a cc_import too (deps on the per-component imports
            # above, no shared_library/static_library of its own), not a cc_library - see this
            # file's top comment for why that matters.
            build_file_parts.append("""
cc_import(
    name = "{formula}",
    defines = {defines},
    deps = {component_import_labels},
)
""".format(
                formula = formula,
                defines = repr(info.get("defines", [])),
                component_import_labels = repr(component_import_labels),
            ))

    repository_ctx.file("BUILD.bazel", "\n".join(build_file_parts))

    # See this function's own top comment (mac_lib_dirs) for why this exists: empty on Linux,
    # one absolute <prefix>/lib directory per macOS formula otherwise.
    repository_ctx.file("lib_dirs.bzl", "MAC_LIB_DIRS = " + repr(mac_lib_dirs) + "\n")

_system_libs_repo = repository_rule(
    implementation = _system_libs_repo_impl,
    local = True,  # re-evaluate every build so `brew upgrade`/`apt install`/etc. is picked up
)

def _system_deps_impl(_module_ctx):
    _system_libs_repo(name = "system_libs")

system_deps = module_extension(implementation = _system_deps_impl)
