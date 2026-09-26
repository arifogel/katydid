"""Wraps system-provided libraries (Boost, FFTW, MatIO) and fetches ROOT, exposed as
@system_libs and @root respectively - via Homebrew on macOS, via apt or dnf on Linux for
Boost/FFTW/MatIO (whichever is actually on PATH - not a hardcoded distro list, so this doesn't
need editing again for the next Linux flavor that shows up).

On Linux, Boost/FFTW/MatIO are exposed as real cc_import targets pointing directly at the
actual, already-installed .so file for each library component (located via known apt/dnf
paths, not a bare -l linker search hint) - not a cc_library with a fake, empty placeholder
source file. These libraries' own compiled implementation already exists on the machine and
was never something Bazel compiles; cc_import represents that directly. This also resolves
cc_shared_library's own "linked statically but not exported" error for a library reachable
from more than one cc_shared_library's own deps (e.g. Boost, needed by both katydid_utility
and nymph) - confirmed directly, empirically: converting these from a cc_library (which does
hit that error, even a header-only one with zero srcs - bazelbuild/bazel#19920) to cc_import
made the error stop naming them at all, with no LINKABLE_MORE_THAN_ONCE tag needed anywhere.
Exactly why cc_import is exempt isn't confirmed from Bazel's own source - the fragments of
_separate_static_and_dynamic_link_libraries examined while investigating this suggested every
deps-reachable node is treated identically regardless of kind, which the actual, observed
build result directly contradicts - but the empirical result itself is solid. If a future
Bazel version's behavior here ever changes, tags = ["LINKABLE_MORE_THAN_ONCE"] on the
per-component cc_import targets below is the fallback, and is genuinely appropriate should it
ever be needed: a cc_import wrapping an already-existing system .so has no compiled code of
its own to duplicate at all, unlike a library actually compiled from source (e.g. @yaml_cpp,
which needs the real fix - a genuine cc_shared_library of its own - since that one does
compile real source and a tag would actually paper over duplicated code there).

ROOT is fetched directly as a prebuilt binary from root.cern, one exact URL per supported
platform, rather than discovered via root-config on PATH: no distro packages a usable ROOT
build, and building it from source is squarely "unreasonable to build from source" territory
(a large, slow build with no existing hermetic Bazel toolchain to lean on). Only the three
platforms this repo's own CI actually supports are covered - Ubuntu 24.04, AlmaLinux 9.x (any
minor version; 9.x is ABI-compatible across the series), and macOS on arm64. ROOT's own
prebuilt binaries are versioned per exact OS release and toolchain (not just "linux" or
"macos"), so unlike Boost/FFTW/MatIO below, this needs to read /etc/os-release on Linux, not
just check which package manager is on PATH.

ROOT is deliberately its own, separate repository (@root), not folded into @system_libs
alongside Boost/FFTW/MatIO, even though @system_libs//:root and @system_libs//:rootcling
remain valid labels (aliased to @root's own targets, so nothing elsewhere in this repo needs
to change). @system_libs needs local = True to re-run on every build, so a brew upgrade/apt
install since the last build is picked up - but ROOT's own version here is a fixed pin in
this file, not host state, so it should only be re-fetched when this file itself changes.
Folding ROOT's own fetch into the same, always-local rule was a real, confirmed bug: it
silently defeated download_and_extract's own cache and re-downloaded the ~300MB tarball on
every single build, regardless of whether anything had actually changed.

Boost/FFTW/MatIO are still discovered from what's already on the machine (Homebrew, apt, dnf)
rather than fetched directly - this is a deliberate trade: none of this is built hermetically
by Bazel, and the exact version you get depends on what's already on the machine. In exchange,
there's no need to compile these from source inside the Bazel graph, and on Linux, apt/dnf-
installed Boost/FFTW/MatIO need no explicit discovery at all - both install into the
compiler/linker's default search paths, unlike Homebrew, which deliberately keeps things out
of the way.

Usage from a BUILD file: deps = ["@system_libs//:boost", "@system_libs//:fftw"]
"""

# Bump this (and nowhere else) to change the ROOT version used everywhere - matches
# ci.yaml's own ROOT_VERSION. Confirm any new version is actually published for every
# platform below at https://root.cern/install/all_releases/ before bumping, and refresh the
# sha256 for each (rules_python's own `uv` toolchain and this repo's own root_dictionary.bzl
# both use the same download_and_extract mechanism, if a worked example is useful).
_ROOT_VERSION = "6.40.04"

# One exact, baked-in URL per supported platform - not a general "any version" table, since
# only the platforms this repo's own CI supports need to work at all. sha256 is intentionally
# blank: computing it requires actually downloading the file, which needs network access to
# root.cern that isn't available in every environment that might edit this file. Bazel's
# download_and_extract works without it (a warning, not an error), but fill these in from a
# real download when possible - they also let Bazel skip re-downloading on a cache hit.
_ROOT_DOWNLOADS = {
    # (linux_distro_id, arch) for Linux; ("macos", arch) for macOS.
    ("ubuntu", "x86_64"): {
        "url": "https://root.cern/download/root_v{v}.Linux-ubuntu24.04-x86_64-gcc13.3.tar.gz",
        "sha256": "",
    },
    ("almalinux", "x86_64"): {
        "url": "https://root.cern/download/root_v{v}.Linux-almalinux9.8-x86_64-gcc11.5.tar.gz",
        "sha256": "",
    },
    ("macos", "aarch64"): {
        "url": "https://root.cern/download/root_v{v}.macos-26.6-arm64-clang210.tar.gz",
        "sha256": "",
    },
}

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

# Normalizes repository_ctx.os.arch ("amd64"/"arm64") to the names _ROOT_DOWNLOADS' own keys
# use ("x86_64"/"aarch64"), matching root.cern's own naming convention. Same normalization
# rocks_analysis_pipeline's own tools/uv/uv_toolchain.bzl uses for the same reason.
def _normalized_arch(repository_ctx):
    arch = repository_ctx.os.arch
    if arch == "amd64":
        return "x86_64"
    if arch == "arm64":
        return "aarch64"
    return arch

# Reads /etc/os-release's ID field directly (e.g. "ubuntu", "almalinux") - this is what ROOT's
# own prebuilt binaries are actually versioned against (an exact OS release, not just "linux"),
# unlike Boost/FFTW/MatIO below, which only need to know which package manager is on PATH.
def _linux_distro_id(repository_ctx):
    os_release = repository_ctx.read("/etc/os-release")
    for line in os_release.splitlines():
        if line.startswith("ID="):
            return line[len("ID="):].strip('"')
    return None

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

def _root_download_key(repository_ctx):
    if _is_macos(repository_ctx):
        return ("macos", _normalized_arch(repository_ctx))
    return (_linux_distro_id(repository_ctx), _normalized_arch(repository_ctx))

def _root_unsupported_platform_error(key):
    return (
        "No prebuilt ROOT {v} binary is configured for {distro}/{arch} in " +
        "tools/system_deps.bzl's own _ROOT_DOWNLOADS table. Supported: {supported}. " +
        "Check https://root.cern/install/all_releases/ for a matching build and add an " +
        "entry, or adjust the version pin if a newer release covers this platform."
    ).format(
        v = _ROOT_VERSION,
        distro = key[0],
        arch = key[1],
        supported = ", ".join(["{}/{}".format(d, a) for d, a in _ROOT_DOWNLOADS.keys()]),
    )

def _root_repo_impl(repository_ctx):
    key = _root_download_key(repository_ctx)
    download = _ROOT_DOWNLOADS.get(key)
    if not download:
        fail(_root_unsupported_platform_error(key))

    # No stripPrefix: root.cern's own tarballs already extract with a top-level root/
    # directory (confirmed directly against ci.yaml's own usage, which extracts to /opt/ and
    # then references /opt/root/bin/rootcling) - this lands it at root/ directly inside this
    # repository, matching what the cc_library below already expects.
    repository_ctx.download_and_extract(
        url = download["url"].format(v = _ROOT_VERSION),
        sha256 = download["sha256"],
    )

    # root-config is part of the tarball just extracted, not something already on PATH -
    # still the most reliable way to get the exact --libs list for this specific build,
    # rather than hardcoding it and risking staleness across ROOT versions.
    root_config = repository_ctx.path("root/bin/root-config")

    # Base libs (Core, RIO, Net, Hist, Graf, Tree, ... ) from root-config, plus the extra
    # COMPONENTS Katydid's CMakeLists.txt explicitly requests via
    # find_package(ROOT 6.00 COMPONENTS Gui Spectrum TMVA) - root-config --libs alone doesn't
    # include those, they have to be added by hand the same way CMake's find_package would.
    root_base_libs_result = repository_ctx.execute([root_config, "--libs"])
    if root_base_libs_result.return_code != 0:
        fail("`root-config --libs` failed on the just-extracted ROOT build:\n" + root_base_libs_result.stderr)
    root_extra_component_libs = ["-lGui", "-lSpectrum", "-lTMVA"]

    root_libdir_result = repository_ctx.execute([root_config, "--libdir"])
    if root_libdir_result.return_code != 0:
        fail("`root-config --libdir` failed on the just-extracted ROOT build:\n" + root_libdir_result.stderr)
    root_libdir = root_libdir_result.stdout.strip()

    root_base_libs = [x for x in root_base_libs_result.stdout.strip().split(" ") if x]
    root_linkopts = (
        root_base_libs +
        root_extra_component_libs +
        ["-Wl,-rpath," + root_libdir]  # ROOT dlopens plugin libs at runtime; needs rpath, not just -L
    )

    repository_ctx.file("BUILD.bazel", """
load("@rules_cc//cc:cc_library.bzl", "cc_library")

package(default_visibility = ["//visibility:public"])

cc_library(
    name = "root",
    srcs = ["_empty.cc"],
    hdrs = glob(["root/include/**"], allow_empty = True),
    includes = ["root/include"],
    # Propagates to every transitive dependent, same reasoning as FFTW_FOUND below - Katydid's
    # code checks #ifdef ROOT_FOUND throughout, matching CMake's `add_definitions(-DROOT_FOUND)`.
    defines = ["ROOT_FOUND"],
    linkopts = {linkopts},
)

exports_files(["rootcling"])
""".format(linkopts = repr(root_linkopts)))

    # cc_shared_library silently drops linkopts from a cc_library with no srcs
    # (bazelbuild/bazel#21884/#27247, a still-open upstream bug; the attempted fix, #24017,
    # was itself reverted). The cc_library above has linkopts and no srcs, so it gets this
    # empty, inert source file as its own srcs.
    repository_ctx.file("_empty.cc", "")

    # Symlinked to the repository root, not referenced as root/bin/rootcling directly: keeps
    # the label @root//:rootcling short, matching what @system_libs//:rootcling aliases to
    # below - tools/root_dictionary.bzl's own _rootcling attribute default references the
    # latter directly.
    repository_ctx.symlink("root/bin/rootcling", "rootcling")

# No local = True, unlike _system_libs_repo below: ROOT's own version is a fixed pin in this
# file, not host state (a brew/apt package version) that can change between builds without
# this file itself changing - Bazel only needs to re-run this when the file changes. Split
# into its own repository specifically so this stays true regardless of what
# _system_libs_repo's own local = True (needed for Boost/FFTW/MatIO's host discovery) does -
# folding ROOT's fetch into that same, always-re-run rule was a real bug: it silently
# defeated download_and_extract's own cache and re-downloaded the ~300MB tarball on every
# single build, confirmed directly, not assumed.
_root_repo = repository_rule(implementation = _root_repo_impl)

def _system_libs_repo_impl(repository_ctx):
    is_macos = _is_macos(repository_ctx)

    build_file_parts = [
        'load("@rules_cc//cc:cc_import.bzl", "cc_import")',
        'load("@rules_cc//cc:cc_library.bzl", "cc_library")',
    ]
    build_file_parts.append('package(default_visibility = ["//visibility:public"])')

    # Aliases, not a real cc_library defined here: ROOT itself is fetched by the separate
    # @root repository above, specifically so its own fixed-version download doesn't get
    # bundled into this repository's own local = True (always re-run) behavior. These keep
    # @system_libs//:root and @system_libs//:rootcling as valid labels unchanged, so nothing
    # elsewhere in this repo (or tools/root_dictionary.bzl's own _rootcling attribute default)
    # needs to be updated to point at @root directly instead.
    build_file_parts.append("""
alias(
    name = "root",
    actual = "@root//:root",
)

alias(
    name = "rootcling",
    actual = "@root//:rootcling",
)
""")

    # cc_shared_library silently drops linkopts from a cc_library with no srcs
    # (bazelbuild/bazel#21884/#27247, a still-open upstream bug; the attempted fix, #24017,
    # was itself reverted). Every cc_library below (boost/fftw/matio on macOS) has linkopts
    # and no srcs, so each gets this empty, inert source file as its own srcs.
    repository_ctx.file("_empty.cc", "")

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
    srcs = ["_empty.cc"],
    hdrs = glob(["{formula}/include/**"], allow_empty = True),
    includes = ["{formula}/include"],
    defines = {defines},
    linkopts = {linkopts},
)
""".format(formula = formula, defines = repr(info.get("defines", [])), linkopts = repr(linkopts)))

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

_system_libs_repo = repository_rule(
    implementation = _system_libs_repo_impl,
    local = True,  # re-evaluate every build so `brew upgrade`/`apt install`/etc. is picked up
)

def _system_deps_impl(_module_ctx):
    _root_repo(name = "root")
    _system_libs_repo(name = "system_libs")

system_deps = module_extension(implementation = _system_deps_impl)
