"""Wraps system-provided libraries (Boost, FFTW, MatIO), exposed as @system_libs - via
Homebrew on macOS, via apt or dnf on Linux (whichever is actually on PATH - not a hardcoded
distro list, so this doesn't need editing again for the next Linux flavor that shows up).

ROOT's own fetch/discovery lives in tools/root.bzl, fully independent of this file: its own
module extension (root_deps) registers @root on its own, and this file's own system_deps
extension knows nothing about it.

On every OS, Boost/FFTW/MatIO are exposed as real cc_import targets pointing directly at the
actual, already-installed .so/.dylib file for each library component (located via known
apt/dnf paths on Linux, via `brew --prefix` on macOS - not a bare -l linker search hint) - not
a cc_library with a fake, empty placeholder source file. These libraries' own compiled
implementation already exists on the machine and was never something Bazel compiles; cc_import
represents that directly. This also resolves cc_shared_library's own "linked statically but
not exported" error for a library reachable from more than one cc_shared_library's own deps
(e.g. Boost, needed by both katydid_utility and nymph) - confirmed directly, empirically:
converting these from a cc_library (which does hit that error, even a header-only one with
zero srcs - bazelbuild/bazel#19920) to cc_import made the error stop naming them at all, with
no LINKABLE_MORE_THAN_ONCE tag needed anywhere. Exactly why cc_import is exempt isn't confirmed
from Bazel's own source - the fragments of _separate_static_and_dynamic_link_libraries examined
while investigating this suggested every deps-reachable node is treated identically regardless
of kind, which the actual, observed build result directly contradicts - but the empirical
result itself is solid. If a future Bazel version's behavior here ever changes, tags =
["LINKABLE_MORE_THAN_ONCE"] on the per-component cc_import targets below is the fallback, and
is genuinely appropriate should it ever be needed: a cc_import wrapping an already-existing
system .so/.dylib has no compiled code of its own to duplicate at all, unlike a library
actually compiled from source (e.g. @yaml_cpp, which needs the real fix - a genuine
cc_shared_library of its own, already in place - since that one does compile real source and a
tag would actually paper over duplicated code there).

Boost/FFTW/MatIO are still discovered from what's already on the machine (Homebrew, apt, dnf)
rather than fetched directly - this is a deliberate trade: none of this is built hermetically
by Bazel, and the exact version you get depends on what's already on the machine. In exchange,
there's no need to compile these from source inside the Bazel graph. The two OSes now differ
only in *how the library is located*, not in what kind of target represents it once found:
apt/dnf-installed Boost/FFTW/MatIO need no explicit -I at all (their headers land on the
compiler's default system include path), while Homebrew deliberately keeps things out of the
way, so macOS still needs `brew --prefix` plus explicit hdrs/includes on the aggregating
cc_import below.

Usage from a BUILD file: deps = ["@system_libs//:boost", "@system_libs//:fftw"]
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

# Linux: apt-installed Boost/FFTW/MatIO need no -I/-L at all (default search paths already
# cover them) - just -l flags. Package names/versions confirmed against Ubuntu 24.04 (noble)'s
# package index directly, not assumed - matio's shared lib is libmatio13, but libmatio-dev
# provides the unversioned libmatio.so symlink needed for a plain -lmatio to resolve, same
# pattern as most -dev packages.
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

# AlmaLinux 9 / RHEL 9 family (dnf). Same "no -I/-L needed" reasoning as apt - dnf also installs
# into the compiler/linker's default search paths. Package names confirmed against the real
# AlmaLinux/EPEL package index, not assumed: boost-devel/fftw-devel/tbb-devel all live in
# AlmaLinux 9's own AppStream repo; matio-devel specifically needs EPEL
# (`dnf install epel-release`) - it isn't in AppStream or CRB.
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
# manager whether a specific package name is "installed" (`dpkg -s` / `rpm -q`). The latter is
# unreliable on Linux in a way worth avoiding: some package managers use "transitional" wrapper
# packages for versioned libraries (e.g. Ubuntu's libboost-filesystem-dev simply depends on the
# real libboost-filesystem1.83-dev), and some caching mechanisms used in CI do not reliably
# register these wrapper packages, even though the underlying files are genuinely present and
# working. Checking for the header directly avoids this: it is what is actually needed, it is
# identical logic on both apt and dnf, and it cannot be fooled by a package manager's internal
# bookkeeping.
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

# Locates the real, already-installed .so file for a library - apt (Debian/Ubuntu multiarch)
# and dnf (RHEL-family lib64) each put it somewhere different, and neither necessarily uses
# the unversioned name a plain -l flag would resolve via the linker's own search path (which
# is what the prior linkopts-only approach relied on). cc_import needs a concrete file, not a
# linker search hint - this finds it directly rather than assuming a single fixed path.
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

# Locates the real, already-installed .dylib file for a library under a formula's own
# `brew --prefix` - unlike Linux's apt/dnf, where the same library can land in one of several
# distro-specific paths, Homebrew always puts it at exactly one place relative to the formula's
# own prefix, so there's a single candidate to check rather than a list.
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

    # Every macOS formula's own absolute <prefix>/lib directory (empty on Linux) - written out
    # below as its own .bzl file so release_binary.bzl/harvest_runtime_libs.bzl can bake these
    # in as extra RPATH entries on the release archive's own binaries/libraries. Necessary
    # because (unlike Linux, where apt/dnf install into the dynamic linker's own default
    # search paths, so a release archive extracted onto a similar machine finds libfftw3.so
    # there without any help) Homebrew never does, and this repo's own docstring already
    # documents Boost/FFTW/MatIO as deliberately *not* bundled/fetched hermetically - discovered
    # from whatever's already on the machine instead. An absolute RPATH entry pointing at this
    # exact build machine's own Homebrew prefix is that same trade-off made explicit for macOS,
    # rather than bundling copies into the release archive's own lib/ (which the actual runtime
    # dependency graph doesn't even surface these libraries' files to in the first place - see
    # harvest_runtime_libs.bzl's own docstring).
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

            # Real cc_import per library component, matching Linux (see this file's top
            # comment): Homebrew's own compiled implementation already exists as a real
            # .dylib, and was never ours to compile - cc_import(shared_library = ...)
            # represents that directly, rather than a cc_library + linkopts, which does hit
            # cc_shared_library's "linked statically but not exported" ODR check.
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

            # hdrs/includes live on this aggregating target, unlike Linux's (where apt/dnf
            # already put the headers on the compiler's default system include path):
            # Homebrew deliberately keeps its own include/ out of the way, and the symlink
            # above is what gives `glob(...)` real files to see at all.
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

            # Real cc_import per library component, not a cc_library with a fake _empty.cc
            # source and a bare -l linkopt: boost/fftw/matio's own compiled implementation
            # already exists as a real .so on the machine, and was never ours to compile in
            # the first place - cc_import(shared_library = ...) represents that directly,
            # pointing at the actual, located file, rather than a linker search hint.
            #
            # Symlinked into this repository first: cc_import's own shared_library attribute
            # takes a label (a file within this repository), not an arbitrary absolute path.
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

            # No hdrs/includes: apt/dnf already put the headers on the compiler's default system
            # include path (/usr/include), which Bazel's auto-configured C++ toolchain always
            # allows inside the sandbox - the same mechanism that makes <vector>/<stdio.h> work
            # without declaring them as hdrs on any target.
            #
            # This aggregating target is itself a cc_import too (no shared_library/
            # static_library of its own, just deps on the per-component imports above), not a
            # cc_library: keeps the whole chain cc_import-shaped, testing directly whether
            # cc_shared_library's own "linked statically but not exported" ODR-reachability
            # check exempts a cc_import node the way it does not exempt a plain cc_library
            # (confirmed it does not, even a header-only one with zero srcs -
            # bazelbuild/bazel#19920).
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
