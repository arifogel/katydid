"""Provides Boost, FFTW, and MatIO for Ubuntu, exposed as @ubuntu_libs - discovered from
apt-installed files already on the compiler/linker's default search paths, so no explicit -I/
symlink-and-wrap-headers dance is needed. Unpinned: uses whatever version `apt install`
currently resolves to (see .github/workflows/ci.yaml's apt install step and BUILDING.md).

Nothing should reference this repo directly - resolution to whichever platform repo is
actually live on the current host happens with no select()/config_setting/flag anywhere.
"""

# Package names/versions confirmed against Ubuntu 24.04 (noble)'s package index: matio's
# shared lib is libmatio13, but libmatio-dev provides the unversioned libmatio.so symlink used
# here, same pattern as most -dev packages.
_APT_LIBS = {
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

# Checked via the actual header each library installs, not via a `dpkg -s` query: Ubuntu's
# libboost-filesystem-dev is a transitional wrapper package depending on the real
# libboost-filesystem1.83-dev, and some CI caching doesn't reliably register these wrapper
# packages even when the files are present.
_HEADER_CHECK = {
    "boost": "usr/include/boost/version.hpp",
    "fftw": "usr/include/fftw3.h",
    "matio": "usr/include/matio.h",
}

def _check_header_or_fail(repository_ctx, formula, header, packages):
    if not repository_ctx.path("/" + header).exists:
        fail("Missing header /{header} (needed for {formula}) - looks like it isn't installed.\nRun:\n  sudo apt install {pkgs}".format(
            header = header,
            formula = formula,
            pkgs = " ".join(packages),
        ))

def _find_shared_lib_or_fail(repository_ctx, libname, packages):
    # Debian/Ubuntu multiarch path, plus a plain /usr/lib/libX.so fallback for the rare
    # package that doesn't use the multiarch layout.
    candidate_paths = [
        "/usr/lib/x86_64-linux-gnu/lib{}.so".format(libname),
        "/usr/lib/lib{}.so".format(libname),
    ]
    for path in candidate_paths:
        if repository_ctx.path(path).exists:
            return path
    fail(
        "Could not find lib{lib}.so in any known location ({paths}) - looks like it isn't " +
        "installed.\nRun:\n  sudo apt install {pkgs}".format(
            lib = libname,
            paths = ", ".join(candidate_paths),
            pkgs = " ".join(packages),
        ),
    )

def _ubuntu_libs_repo_impl(repository_ctx):
    build_file_parts = [
        'load("@rules_cc//cc:cc_import.bzl", "cc_import")',
        'package(default_visibility = ["//visibility:public"])',
    ]
    for formula, info in _APT_LIBS.items():
        _check_header_or_fail(repository_ctx, formula, _HEADER_CHECK[formula], info["packages"])

        # Symlinked into this repository first, then wrapped as cc_import.
        component_import_labels = []
        for lib in info["libs"]:
            so_path = _find_shared_lib_or_fail(repository_ctx, lib, info["packages"])
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

        # No hdrs/includes: apt already put the headers on the compiler's default system
        # include path.
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

_ubuntu_libs_repo = repository_rule(
    implementation = _ubuntu_libs_repo_impl,
    local = True,  # re-evaluate every build so `apt install`/upgrade is picked up
)

def _ubuntu_libs_impl(_module_ctx):
    _ubuntu_libs_repo(name = "ubuntu_libs")

ubuntu_libs = module_extension(implementation = _ubuntu_libs_impl)
