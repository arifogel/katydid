"""Wraps system-provided libraries (Boost, FFTW, MatIO), exposed as @system_libs - via
Homebrew on macOS, via apt or dnf on Linux (whichever is on PATH, so a new Linux flavor needs
no edit here).

ROOT's fetch/discovery lives in tools/root.bzl, fully independent of this file.

Boost/FFTW/MatIO are exposed as cc_import targets pointing at the already-installed .so/.dylib
for each library component (apt/dnf's known paths on Linux, `brew --prefix` on macOS). This is
also what fixes cc_shared_library's "linked statically but not exported" error for a library
reachable from more than one cc_shared_library's deps (e.g. Boost, needed by both
katydid_utility and nymph): cc_import is exempt from that check, cc_library is not, even a
header-only cc_library with zero srcs (bazelbuild/bazel#19920). If a future Bazel version's
behavior here changes, tags = ["LINKABLE_MORE_THAN_ONCE"] on the per-component cc_import
targets below is the fallback - safe here since a cc_import wrapping an existing system
.so/.dylib has no compiled code of its own to duplicate, unlike a library actually compiled
from source (e.g. @yaml_cpp, which needs its own cc_shared_library instead).

Boost/FFTW/MatIO are discovered from what's already on the machine rather than fetched
hermetically, so the exact version depends on what's installed. The two OSes differ only in
how the library is located: apt/dnf-installed Boost/FFTW/MatIO need no explicit -I (headers
land on the compiler's default system include path); Homebrew keeps things out of the way, so
macOS needs `brew --prefix` plus explicit hdrs/includes on the aggregating cc_import below.

On AlmaLinux specifically, Boost and FFTW are the one exception to "discovered from what's
already on the machine": AlmaLinux's dnf repos are rolling and prune a package once a newer
build supersedes it, so host discovery there isn't reproducible the way apt/Homebrew's is.
linux_distro_id (tools/repo_utils.bzl) detects AlmaLinux from inside this repository rule -
the same place tools/root.bzl already auto-detects platform - and switches to fetching pinned
.rpm packages hermetically instead (see tools/rpm_deps.bzl for that fetch logic); either way,
the exposed label is still @system_libs//:boost / @system_libs//:fftw, so no BUILD file needs
to know or care which path was taken. MatIO is unaffected and always uses host discovery,
since nothing here pins a specific MatIO version.

Usage from a BUILD file: deps = ["@system_libs//:boost", "@system_libs//:fftw"]
"""

load(":repo_utils.bzl", "is_macos", "linux_distro_id")
load(
    ":rpm_deps.bzl",
    "EXTRACTED_LIBS",
    "ROOT_RUNTIME_EXTRA_LIBS",
    "RPM_DOWNLOADS",
    "cc_import_snippet",
    "check_is_elf_or_fail",
    "download_and_extract_rpm",
)

_MAC_FORMULAE = {
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

# apt puts Boost/FFTW/MatIO's .so files and headers on the compiler/linker's default search
# paths. Package names/versions confirmed against Ubuntu 24.04 (noble)'s package index: matio's
# shared lib is libmatio13, but libmatio-dev provides the unversioned libmatio.so symlink used
# here, same pattern as most -dev packages.
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

# AlmaLinux 9 / RHEL 9 family (dnf). Same default-search-path story as apt. Package names
# confirmed against the AlmaLinux/EPEL package index: boost-devel/fftw-devel live in AlmaLinux
# 9's AppStream repo; matio-devel needs EPEL (`dnf install epel-release`) - not in AppStream or
# CRB.
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

# Checked via the actual header each library installs, not via the package manager's own
# "is this installed" query (dpkg -s / rpm -q): some package managers use transitional wrapper
# packages for versioned libraries (e.g. Ubuntu's libboost-filesystem-dev depends on the real
# libboost-filesystem1.83-dev), and some CI caching doesn't reliably register these wrapper
# packages even when the files are present.
_LINUX_HEADER_CHECK = {
    "boost": "usr/include/boost/version.hpp",
    "fftw": "usr/include/fftw3.h",
    "matio": "usr/include/matio.h",
}

# Distinguishes apt vs dnf by which package manager binary is on PATH rather than parsing
# /etc/os-release or hardcoding distro names, so a new Linux flavor needs no edit here.
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

# apt (Debian/Ubuntu multiarch) and dnf (RHEL-family lib64) install to different absolute
# paths, checked in order.
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

# Homebrew always puts it at exactly one place (unlike apt/dnf), so there's a single
# candidate to check.
def _find_mac_dylib_or_fail(repository_ctx, prefix, libname, brew_formula):
    path = "{}/lib/lib{}.dylib".format(prefix, libname)
    if repository_ctx.path(path).exists:
        return path
    fail(
        "Could not find {path} - looks like `brew install {f}` didn't provide it, or " +
        "Homebrew's layout for this formula has changed.".format(path = path, f = brew_formula),
    )

def _system_libs_repo_impl(repository_ctx):
    on_macos = is_macos(repository_ctx)
    on_almalinux = False  # only ever True on Linux; see the dnf branch below

    build_file_parts = [
        'load("@rules_cc//cc:cc_import.bzl", "cc_import")',
    ]
    build_file_parts.append('package(default_visibility = ["//visibility:public"])')

    # Every macOS formula's absolute <prefix>/lib directory (empty on Linux), written out below
    # as its own .bzl file so release_binary.bzl/harvest_runtime_libs.bzl can bake these in as
    # extra RPATH entries (see harvest_runtime_libs.bzl's docstring for why).
    mac_lib_dirs = []

    # Homebrew keeps headers out of the default include path (needs explicit hdrs/includes,
    # found via `brew --prefix`); apt puts them on it (needs neither).
    if on_macos:
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

            # Symlinks brew's include dir into this repo (needed for hdrs = glob(...) below).
            repository_ctx.symlink(prefix + "/include", formula + "/include")

            # Real cc_import per library component, matching Linux (see module docstring).
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

        # AlmaLinux 9's dnf repos are rolling (see module docstring), so Boost/FFTW there come
        # from tools/rpm_deps.bzl's hermetic pinned-.rpm fetch instead of the host-discovery
        # loop below - detected here, inside the repository rule, the same way tools/root.bzl
        # already auto-detects platform, rather than via a build-time flag a select() would
        # need to read.
        on_almalinux = pkg_manager == "dnf" and linux_distro_id(repository_ctx) == "almalinux"
        hermetic_formulas = ["boost", "fftw"] if on_almalinux else []

        if on_almalinux:
            for pkg_name in RPM_DOWNLOADS:
                download_and_extract_rpm(repository_ctx, pkg_name)

            for pkg_name, source_path, runtime_name in EXTRACTED_LIBS:
                src = "{}_extracted/{}".format(pkg_name, source_path)
                check_is_elf_or_fail(repository_ctx, src, pkg_name, source_path)
                repository_ctx.symlink(src, runtime_name)

            build_file_parts.extend(cc_import_snippet(
                name = "boost",
                so_names = [
                    "libboost_filesystem.so.1.75.0",
                    "libboost_thread.so.1.75.0",
                    "libboost_date_time.so.1.75.0",
                    "libboost_program_options.so.1.75.0",
                ],
                hdrs_glob = ["boost-devel_extracted/usr/include/boost/**"],
                includes = ["boost-devel_extracted/usr/include"],
            ))
            build_file_parts.extend(cc_import_snippet(
                name = "fftw",
                so_names = ["libfftw3.so.3"],
                hdrs_glob = ["fftw-devel_extracted/usr/include/fftw3.h"],
                includes = ["fftw-devel_extracted/usr/include"],
            ))

        for formula, info in linux_libs.items():
            if formula in hermetic_formulas:
                continue

            _check_header_or_fail(
                repository_ctx,
                formula,
                _LINUX_HEADER_CHECK[formula],
                info["packages"],
                install_hint,
            )

            # Symlinked into this repository first, then wrapped as cc_import.
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
            # system include path.
            #
            # This aggregating target is a cc_import too (see module docstring for why), just
            # deps on the per-component imports above.
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

    # TBB/xxhash/FreeType/GSL: needed only because ROOT's own prebuilt binaries link against
    # them (nothing here #includes their headers), and only on AlmaLinux, where they're bundled
    # into a release archive directly (see root BUILD.bazel) rather than resolved via the
    # system linker's default paths as on Ubuntu/macOS - so this filegroup is empty everywhere
    # except AlmaLinux, and BUILD files reference @system_libs//:root_runtime_extra_libs
    # unconditionally, with no select() needed to pick a platform-specific label.
    build_file_parts.append("""
filegroup(
    name = "root_runtime_extra_libs",
    srcs = {srcs},
)
""".format(srcs = repr(ROOT_RUNTIME_EXTRA_LIBS if on_almalinux else [])))

    repository_ctx.file("BUILD.bazel", "\n".join(build_file_parts))

    # See mac_lib_dirs above: empty on Linux, one absolute <prefix>/lib directory per macOS
    # formula otherwise.
    repository_ctx.file("lib_dirs.bzl", "MAC_LIB_DIRS = " + repr(mac_lib_dirs) + "\n")

_system_libs_repo = repository_rule(
    implementation = _system_libs_repo_impl,
    local = True,  # re-evaluate every build so `brew upgrade`/`apt install`/etc. is picked up
)

def _system_deps_impl(_module_ctx):
    _system_libs_repo(name = "system_libs")

system_deps = module_extension(implementation = _system_deps_impl)
