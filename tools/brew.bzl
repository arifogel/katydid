"""Shared Homebrew helper functions: locating formula prefixes/dylibs and building cc_import
BUILD.bazel snippets.
"""

# Katydid's Boost/FFTW/MatIO Homebrew formulae: {exposed name: {libs, defines, brew_formula}}.
# brew_formula defaults to the exposed name; set only where Homebrew's formula name differs
# (e.g. "libmatio" for MatIO - Homebrew's own formula name doesn't always match Katydid's
# target name).
MAC_BREW_FORMULAE = {
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
    "matio": {
        "brew_formula": "libmatio",
        "libs": ["matio"],
    },
}

def brew_require(repository_ctx):
    """Returns the `brew` binary's path, failing with an install hint if it's not on PATH.

    Args:
        repository_ctx: the calling repository_rule's repository_ctx.

    Returns:
        The absolute path to the `brew` binary.
    """
    brew = repository_ctx.which("brew")
    if not brew:
        fail(
            "`brew` was not found on PATH. Install Homebrew (https://brew.sh), then " +
            "`brew install boost fftw libmatio`, or adjust tools/macos_libs.bzl if your " +
            "libraries live somewhere else (e.g. MacPorts, conda).",
        )
    return brew

def brew_prefix(repository_ctx, brew, formula):
    """Returns `brew --prefix <formula>`'s absolute path, failing with an install hint.

    Args:
        repository_ctx: the calling repository_rule's repository_ctx.
        brew: the `brew` binary's path (from brew_require).
        formula: the Homebrew formula name.

    Returns:
        The formula's absolute install prefix.
    """
    result = repository_ctx.execute([brew, "--prefix", formula])
    if result.return_code != 0:
        fail(
            "`brew --prefix {f}` failed - run `brew install {f}`.\n{err}".format(
                f = formula,
                err = result.stderr,
            ),
        )
    return result.stdout.strip()

# Homebrew always puts a formula's dylib at exactly one place, so there's a single candidate
# to check.
def _find_dylib_or_fail(repository_ctx, prefix, libname, brew_formula):
    path = "{}/lib/lib{}.dylib".format(prefix, libname)
    if repository_ctx.path(path).exists:
        return path
    fail(
        "Could not find {path} - looks like `brew install {f}` didn't provide it, or " +
        "Homebrew's layout for this formula has changed.".format(path = path, f = brew_formula),
    )

def brew_cc_import_snippet(repository_ctx, brew, dest_prefix, brew_formula, libs, defines = []):
    """Symlinks a Homebrew formula's headers/libs into dest_prefix/ inside the calling repo.

    Args:
        repository_ctx: the calling repository_rule's repository_ctx.
        brew: the `brew` binary's path (from brew_require).
        dest_prefix: both the cc_import's target name and the directory (inside the calling
            repo) headers/libs get symlinked under - e.g. "boost" for @macos_libs//:boost.
        brew_formula: the Homebrew formula name (e.g. "libmatio" for MatIO - Homebrew's own
            formula name doesn't always match Katydid's target name).
        libs: library base names (e.g. "boost_filesystem" for libboost_filesystem.dylib).
        defines: defines to attach to the aggregating cc_import (e.g. ["FFTW_FOUND"]).

    Returns:
        A (build_file_text_parts, absolute_lib_dir) pair: the BUILD.bazel text for a cc_import
        named `dest_prefix` exposing the formula (plus one per-component cc_import it depends
        on), and the formula's absolute <prefix>/lib directory, for RPATH use.
    """
    prefix = brew_prefix(repository_ctx, brew, brew_formula)

    # Symlinks brew's include dir into the calling repo, needed for hdrs = glob(...) below:
    # Homebrew keeps headers out of the default system include path.
    repository_ctx.symlink(prefix + "/include", dest_prefix + "/include")

    component_import_labels = []
    parts = []
    for lib in libs:
        dylib_path = _find_dylib_or_fail(repository_ctx, prefix, lib, brew_formula)
        symlink_name = "{}/lib{}.dylib".format(dest_prefix, lib)
        repository_ctx.symlink(dylib_path, symlink_name)

        import_name = "_{}_{}_import".format(dest_prefix, lib)
        component_import_labels.append(":" + import_name)
        parts.append("""
cc_import(
    name = "{import_name}",
    shared_library = "{symlink_name}",
)
""".format(import_name = import_name, symlink_name = symlink_name))

    parts.append("""
cc_import(
    name = "{name}",
    hdrs = glob(["{name}/include/**"], allow_empty = True),
    includes = ["{name}/include"],
    defines = {defines},
    deps = {component_import_labels},
)
""".format(
        name = dest_prefix,
        defines = repr(defines),
        component_import_labels = repr(component_import_labels),
    ))
    return parts, prefix + "/lib"
