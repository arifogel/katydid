"""Fetches ROOT, exposed as @root.

ROOT is fetched directly as a prebuilt binary from root.cern, one exact URL per supported
platform, rather than discovered via root-config on PATH: no distro packages a usable ROOT
build, and building it from source is squarely "unreasonable to build from source" territory
(a large, slow build with no existing hermetic Bazel toolchain to lean on). Only the three
platforms this repo's own CI actually supports are covered - Ubuntu 24.04, AlmaLinux 9.x (any
minor version; 9.x is ABI-compatible across the series), and macOS on arm64. ROOT's own
prebuilt binaries are versioned per exact OS release and toolchain (not just "linux" or
"macos"), so unlike Boost/FFTW/MatIO (see tools/system_deps.bzl), this needs to read
/etc/os-release on Linux, not just check which package manager is on PATH.

ROOT is deliberately its own, separate repository (@root), not folded into @system_libs
alongside Boost/FFTW/MatIO: @system_libs needs local = True to re-run on every build, so a
brew upgrade/apt install since the last build is picked up - but ROOT's own version here is a
fixed pin in this file, not host state, so it should only be re-fetched when this file itself
changes. Folding ROOT's own fetch into the same, always-local rule was a real, confirmed bug:
it silently defeated download_and_extract's own cache and re-downloaded the ~300MB tarball on
every single build, regardless of whether anything had actually changed. Every consumer
references @root directly (e.g. deps = ["@root"]) - there is no @system_libs//:root alias, to
avoid exactly the confusion a same-named alias into a different repository invites.

root_repo (the repository_rule below) is registered from tools/system_deps.bzl's own
system_deps module extension, alongside @system_libs - not from a separate module extension of
its own - so MODULE.bazel's own use_extension/use_repo calls didn't need to change when this
file was split out.
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
        "sha256": "0fb35191ed9b3847abd9ab5f25878845545a5acc16a4465ca1f4310bd63191a8",
    },
    ("almalinux", "x86_64"): {
        "url": "https://root.cern/download/root_v{v}.Linux-almalinux9.8-x86_64-gcc11.5.tar.gz",
        "sha256": "00e2fea3cde708c135bf35f2421031a5d036770604652d137b2e65badb01356d",
    },
    ("macos", "aarch64"): {
        "url": "https://root.cern/download/root_v{v}.macos-26.6-arm64-clang210.tar.gz",
        "sha256": "325f1329bd4af4fe108615d63926d27087ad98ad6a1c359d55f717ca76ef9314",
    },
}

# Duplicated from tools/system_deps.bzl's own _is_macos rather than shared via load(): a
# leading-underscore Starlark symbol is private to the file that defines it and can't be
# loaded elsewhere, and this is a two-line helper - not worth making public in one file just
# to import it into another.
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
# unlike Boost/FFTW/MatIO, which only need to know which package manager is on PATH.
def _linux_distro_id(repository_ctx):
    os_release = repository_ctx.read("/etc/os-release")
    for line in os_release.splitlines():
        if line.startswith("ID="):
            return line[len("ID="):].strip('"')
    return None

def _root_download_key(repository_ctx):
    if _is_macos(repository_ctx):
        return ("macos", _normalized_arch(repository_ctx))
    return (_linux_distro_id(repository_ctx), _normalized_arch(repository_ctx))

def _root_unsupported_platform_error(key):
    return (
        "No prebuilt ROOT {v} binary is configured for {distro}/{arch} in " +
        "tools/root.bzl's own _ROOT_DOWNLOADS table. Supported: {supported}. " +
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
    # repository, matching what the targets below already expect.
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
    #
    # Every Katydid module gets the full set here (not scoped per module to just what it
    # actually calls into), matching the CMake reference build's own approach directly:
    # confirmed by reading it, the top-level CMakeLists.txt makes one global
    # find_package(ROOT COMPONENTS Gui Spectrum TMVA) call and links the full
    # ${ROOT_LIBRARIES} set into every target via pbuilder_add_ext_libraries - no per-module
    # CMakeLists.txt scopes this more narrowly. The reference build's own, smaller, per-module
    # NEEDED sets (confirmed via readelf) come entirely from the system compiler's own default
    # --as-needed linker behavior pruning unused entries at link time, not from anything CMake
    # itself does - Bazel's own default toolchain is not confirmed to do the same pruning, so
    # this may end up less minimal than the reference build's own NEEDED sets. Not a
    # correctness concern either way: an unused DT_NEEDED entry just means an extra library
    # gets loaded at process start.
    root_base_libs_result = repository_ctx.execute([root_config, "--libs"])
    if root_base_libs_result.return_code != 0:
        fail("`root-config --libs` failed on the just-extracted ROOT build:\n" + root_base_libs_result.stderr)
    root_extra_component_libs = ["-lGui", "-lSpectrum", "-lTMVA"]

    # root-config --libs's own tokens, split into three buckets: -l entries (library names,
    # handled below), -L entries (a search-path hint cc_import doesn't need, since
    # shared_library references the exact file directly - intentionally dropped), and
    # everything else (e.g. -pthread, -rdynamic - genuine linker flags with no library name
    # to extract, preserved verbatim as linkopts, the same way the prior, pre-cc_import
    # version of this code did for every token here).
    all_root_libs_tokens = root_base_libs_result.stdout.strip().split(" ") + root_extra_component_libs
    root_lib_names = [x[2:] for x in all_root_libs_tokens if x.startswith("-l")]
    root_other_linkopts = [x for x in all_root_libs_tokens if x and not x.startswith("-l") and not x.startswith("-L")]

    root_srcs = [
        "root/lib/lib{}.so".format(lib_name)
        for lib_name in root_lib_names
        if repository_ctx.path("root/lib/lib{}.so".format(lib_name)).exists
    ]
    root_linkopts = root_other_linkopts + [
        "-l" + lib_name
        for lib_name in root_lib_names
        if not repository_ctx.path("root/lib/lib{}.so".format(lib_name)).exists
    ]

    repository_ctx.file("BUILD.bazel", """
load("@rules_cc//cc:cc_library.bzl", "cc_library")

package(default_visibility = ["//visibility:public"])

cc_library(
    name = "root",
    hdrs = glob(["root/include/**"], allow_empty = True),
    includes = ["root/include"],
    defines = ["ROOT_FOUND"],
    srcs = {srcs},
    linkopts = {linkopts},
)

exports_files(["rootcling"])
""".format(srcs = repr(root_srcs), linkopts = repr(root_linkopts)))

    # Symlinked to the repository root, not referenced as root/bin/rootcling directly: keeps
    # the label @root//:rootcling short - tools/root_dictionary.bzl's own _rootcling attribute
    # default references it directly.
    repository_ctx.symlink("root/bin/rootcling", "rootcling")

# No local = True, unlike system_deps.bzl's own _system_libs_repo: ROOT's own version is a
# fixed pin in this file, not host state (a brew/apt package version) that can change between
# builds without this file itself changing - Bazel only needs to re-run this when the file
# changes. Split into its own repository specifically so this stays true regardless of what
# _system_libs_repo's own local = True (needed for Boost/FFTW/MatIO's host discovery) does -
# folding ROOT's fetch into that same, always-re-run rule was a real bug: it silently
# defeated download_and_extract's own cache and re-downloaded the ~300MB tarball on every
# single build, confirmed directly, not assumed.
root_repo = repository_rule(implementation = _root_repo_impl)
