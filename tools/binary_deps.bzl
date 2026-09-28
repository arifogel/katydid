"""Resolves Boost/FFTW/MatIO to whichever platform-specific repository actually provides them on
this host, exposed as @binary_deps. On AlmaLinux, this also covers the extra runtime libs ROOT's
own prebuilt binaries need. This is the one label surface any BUILD file should reference
(deps = ["@binary_deps//:boost", "@binary_deps//:fftw"]); tools/macos_libs.bzl,
tools/ubuntu_libs.bzl, and tools/almalinux_libs.bzl are retrieval-only and nothing outside this
file should reference them directly.
"""

load(":brew.bzl", "brew_prefix", "brew_require")
load(":repo_utils.bzl", "is_macos", "linux_distro_id")

# {dependency: {host_key: underlying label}} - see tools/macos_libs.bzl, tools/ubuntu_libs.bzl,
# tools/almalinux_libs.bzl for what each label actually is.
_LIBS = {
    "boost": {
        "mac": "@macos_libs//:boost",
        "ubuntu": "@ubuntu_libs//:boost",
        "almalinux": "@almalinux_libs//:boost",
    },
    "fftw": {
        "mac": "@macos_libs//:fftw",
        "ubuntu": "@ubuntu_libs//:fftw",
        "almalinux": "@almalinux_libs//:fftw",
    },
    "matio": {
        "mac": "@macos_libs//:matio",
        "ubuntu": "@ubuntu_libs//:matio",
        "almalinux": "@almalinux_libs//:matio",
    },
}

# Homebrew formula names for the LIB_DIRS/RPATH computation below, duplicated by hand rather
# than loaded from a shared generated source: loading one here would force @macos_libs to be
# fetched on every platform this file runs on, defeating the laziness this file exists to
# preserve (see the module docstring).
_MAC_BREW_FORMULAE = ["boost", "fftw", "libmatio"]

def _host_key(repository_ctx):
    if is_macos(repository_ctx):
        return "mac"
    distro = linux_distro_id(repository_ctx)
    if distro == "almalinux":
        return "almalinux"
    if repository_ctx.which("apt-get"):
        return "ubuntu"
    fail(
        "tools/binary_deps.bzl doesn't know which platform repo (tools/macos_libs.bzl, " +
        "tools/ubuntu_libs.bzl, tools/almalinux_libs.bzl) to use on this host " +
        "(linux_distro_id = {}) - add a branch for it.".format(repr(distro)),
    )

def _binary_deps_repo_impl(repository_ctx):
    key = _host_key(repository_ctx)

    build_file_parts = ['package(default_visibility = ["//visibility:public"])']
    for name, by_host in _LIBS.items():
        build_file_parts.append('alias(name = "{}", actual = "{}")'.format(name, by_host[key]))

    # TBB/xxhash/FreeType/GSL: needed only because ROOT's own prebuilt binaries link against
    # them, and only on AlmaLinux, where tools/almalinux_libs.bzl fetches them hermetically.
    # A real, empty filegroup everywhere else, so consumers can reference this unconditionally
    # with no select() of their own.
    if key == "almalinux":
        build_file_parts.append('alias(name = "root_runtime_extra_libs", actual = "@almalinux_libs//:root_runtime_extra_libs")')
    else:
        build_file_parts.append('filegroup(name = "root_runtime_extra_libs", srcs = [])')

    repository_ctx.file("BUILD.bazel", "\n".join(build_file_parts))

    # Extra RPATH directories to bake in at release-packaging time on macOS, where Homebrew
    # keeps formulae off the default library search path. Empty everywhere else. Computed
    # directly via tools/brew.bzl rather than a shared generated source (see _MAC_BREW_FORMULAE
    # above for why).
    lib_dirs = []
    if key == "mac":
        brew = brew_require(repository_ctx)
        for formula in _MAC_BREW_FORMULAE:
            lib_dirs.append(brew_prefix(repository_ctx, brew, formula) + "/lib")

    # One '-add_rpath <dir>' per entry in lib_dirs, ready to splice into an install_name_tool
    # command line.
    mac_extra_rpath_flags = " ".join(["-add_rpath '{}'".format(d) for d in lib_dirs])

    repository_ctx.file(
        "lib_dirs.bzl",
        "LIB_DIRS = " + repr(lib_dirs) + "\n" +
        "MAC_EXTRA_RPATH_FLAGS = " + repr(mac_extra_rpath_flags) + "\n",
    )

_binary_deps_repo = repository_rule(
    implementation = _binary_deps_repo_impl,
    local = True,  # re-evaluate every build so a platform/host change is picked up
)

def _binary_deps_impl(_module_ctx):
    _binary_deps_repo(name = "binary_deps")

binary_deps = module_extension(implementation = _binary_deps_impl)
