"""Fetches ROOT, exposed as @root.

ROOT is fetched as a prebuilt binary from root.cern, one exact URL per supported platform,
rather than discovered via root-config on PATH: no distro packages a usable ROOT build, and
building it from source has no existing hermetic Bazel toolchain to lean on. Only the three
platforms this repo's CI supports are covered - Ubuntu 24.04, AlmaLinux 9.x (any minor
version; ABI-compatible across the series), and macOS on arm64. ROOT's prebuilt binaries are
versioned per exact OS release and toolchain, not just "linux" or "macos", so unlike
Boost/FFTW/MatIO (see tools/system_deps.bzl) this reads /etc/os-release on Linux rather than
just checking which package manager is on PATH.

ROOT is its own repository (@root), not folded into @system_libs: @system_libs uses
local = True so a brew/apt upgrade is picked up on the next build, but ROOT's version here is
a fixed pin in this file, so it should only be re-fetched when the file changes. Folding
ROOT's fetch into that always-local rule defeated download_and_extract's cache and
re-downloaded the ~300MB tarball on every build regardless of whether anything had changed.
Every consumer references @root directly (deps = ["@root"]); there is no
@system_libs//:root alias, to avoid the confusion a same-named alias into a different
repository would invite.

root_repo (the repository_rule below) is registered by this file's own module extension
(root_deps, at the bottom), independent of system_deps.bzl's system_deps extension, which
registers @system_libs and knows nothing about @root.
"""

# Bump this (and nowhere else) to change the ROOT version used everywhere - matches
# ci.yaml's ROOT_VERSION. Confirm any new version is published for every platform below at
# https://root.cern/install/all_releases/ before bumping, and refresh the sha256 for each.
_ROOT_VERSION = "6.40.04"

# One exact, baked-in URL per supported platform - only the platforms this repo's CI supports
# need to work. sha256 is intentionally blank when not yet computed: computing it requires
# downloading the file, and root.cern isn't reachable from every environment that edits this
# file. download_and_extract works without it (a warning, not an error), but fill it in from a
# real download when possible - it also lets Bazel skip re-downloading on a cache hit.
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

# Duplicated from tools/system_deps.bzl's _is_macos rather than shared via load(): a
# leading-underscore Starlark symbol is private to its file and can't be loaded elsewhere,
# and this two-line helper isn't worth making public just to share.
def _is_macos(repository_ctx):
    return repository_ctx.os.name.lower().startswith("mac")

# Normalizes repository_ctx.os.arch ("amd64"/"arm64") to the names _ROOT_DOWNLOADS' keys use
# ("x86_64"/"aarch64"), matching root.cern's naming convention.
def _normalized_arch(repository_ctx):
    arch = repository_ctx.os.arch
    if arch == "amd64":
        return "x86_64"
    if arch == "arm64":
        return "aarch64"
    return arch

# Reads /etc/os-release's ID field (e.g. "ubuntu", "almalinux") - this is what ROOT's
# prebuilt binaries are versioned against, unlike Boost/FFTW/MatIO which only need to know
# which package manager is on PATH.
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

# Reads a .so's DT_NEEDED entries via readelf -d, returning each as a bare filename (e.g.
# "libROOTNTupleBrowse.so"). Used below to expand root_lib_names into the transitive closure
# of ROOT-internal dependencies; readelf is standard binutils, present on every supported
# Linux platform (not used on macOS - see the comment where this is called).
def _so_needed_names(repository_ctx, so_path):
    result = repository_ctx.execute(["readelf", "-d", str(so_path)])
    if result.return_code != 0:
        # Not fatal: if readelf isn't available or the file can't be read, this .so's
        # transitive dependencies just don't get discovered - the explicit allowlist entries
        # (root_lib_names, from root-config --libs) still work regardless.
        return []
    needed = []
    for line in result.stdout.splitlines():
        if "(NEEDED)" not in line:
            continue

        # e.g. ' 0x0000000000000001 (NEEDED)             Shared library: [libGui.so]'
        start = line.find("[")
        end = line.find("]")
        if start != -1 and end != -1 and end > start:
            needed.append(line[start + 1:end])
    return needed

def _root_repo_impl(repository_ctx):
    key = _root_download_key(repository_ctx)
    download = _ROOT_DOWNLOADS.get(key)
    if not download:
        fail(_root_unsupported_platform_error(key))

    # No stripPrefix: root.cern's tarballs already extract with a top-level root/ directory,
    # landing it at root/ directly inside this repository, matching what the targets below
    # expect.
    repository_ctx.download_and_extract(
        url = download["url"].format(v = _ROOT_VERSION),
        sha256 = download["sha256"],
    )

    # root-config is part of the tarball just extracted, not something already on PATH - the
    # most reliable way to get the exact --libs list for this build, rather than hardcoding
    # it and risking staleness across ROOT versions.
    root_config = repository_ctx.path("root/bin/root-config")

    # Base libs (Core, RIO, Net, Hist, Graf, Tree, ...) from root-config, plus the extra
    # COMPONENTS Katydid's CMakeLists.txt requests via
    # find_package(ROOT 6.00 COMPONENTS Gui Spectrum TMVA) - root-config --libs alone doesn't
    # include those, so they're added by hand the same way CMake's find_package would.
    #
    # Every Katydid module gets the full set here (not scoped per module to just what it
    # calls into), matching the CMake reference build: its top-level CMakeLists.txt makes one
    # global find_package(ROOT COMPONENTS Gui Spectrum TMVA) call and links the full
    # ${ROOT_LIBRARIES} set into every target - no per-module CMakeLists.txt scopes this more
    # narrowly. The reference build's smaller, per-module NEEDED sets come from the system
    # compiler's default --as-needed linker behavior pruning unused entries at link time, not
    # from anything CMake does; Bazel's default toolchain may not prune the same way, so this
    # can end up less minimal. Not a correctness concern: an unused DT_NEEDED entry just means
    # an extra library gets loaded at process start.
    root_base_libs_result = repository_ctx.execute([root_config, "--libs"])
    if root_base_libs_result.return_code != 0:
        fail("`root-config --libs` failed on the just-extracted ROOT build:\n" + root_base_libs_result.stderr)
    root_extra_component_libs = ["-lGui", "-lSpectrum", "-lTMVA"]

    # root-config --libs's tokens, split into three buckets: -l entries (library names,
    # handled below), -L entries (a search-path hint cc_import doesn't need, since
    # shared_library references the exact file directly - intentionally dropped), and
    # everything else (e.g. -pthread, -rdynamic - linker flags with no library name to
    # extract, preserved verbatim as linkopts).
    all_root_libs_tokens = root_base_libs_result.stdout.strip().split(" ") + root_extra_component_libs
    root_lib_names = [x[2:] for x in all_root_libs_tokens if x.startswith("-l")]
    root_other_linkopts = [x for x in all_root_libs_tokens if x and not x.startswith("-l") and not x.startswith("-L")]

    # Expand root_lib_names into the transitive closure of ROOT-internal dependencies before
    # computing srcs below. root-config --libs plus the hand-added Gui/Spectrum/TMVA
    # components only names libraries Katydid calls into *directly* - it misses libraries that
    # are purely internal, transitive dependencies of those (e.g. libGui.so itself has a
    # NEEDED entry on libROOTNTupleBrowse.so, which never shows up in root-config --libs since
    # nothing outside ROOT ever names it directly - likewise libMinuit.so/libMLP.so/
    # libXMLIO.so). cc_library(srcs = [...]) puts every file listed here into one shared solib
    # directory at runtime, and each .so's baked-in RUNPATH ($ORIGIN/.) only finds a sibling
    # that's actually present in srcs - so a missing transitive dependency here is a silent
    # runtime failure ("cannot open shared object file"), not caught by analysis or
    # compilation, only by running the binary.
    #
    # Reading each selected .so's NEEDED entries and repeating until the set stops growing
    # finds every one of these automatically, without hand-maintaining a second list - and
    # without pulling in libCPyCppyy.so (ROOT's Python bindings, needing an unbundled
    # libpythonX.so at *link* time - the original problem that made a hand-picked allowlist
    # necessary instead of a blanket glob(root/lib/*.so)), since nothing this closure needs
    # depends on it.
    #
    # readelf-based, so Linux-only: on macOS these libraries are linked by real (not
    # RPATH-relative) install-name references resolved via Homebrew's linked library layout,
    # not Bazel's solib scattering, so this closure-expansion step is skipped there and
    # root_lib_names is used as-is.
    if not _is_macos(repository_ctx):
        selected = {name: True for name in root_lib_names}
        frontier = list(root_lib_names)

        # Starlark has no while loop - bounded for loop instead, breaking early once the
        # closure stops growing. 50 is far more than ROOT's internal dependency graph could
        # ever need; the bound exists only so the loop is expressible in Starlark, not because
        # 50 is a meaningful limit here.
        for _ in range(50):
            if not frontier:
                break
            next_frontier = []
            for lib_name in frontier:
                so_file = repository_ctx.path("root/lib/lib{}.so".format(lib_name))
                if not so_file.exists:
                    continue
                for needed_so in _so_needed_names(repository_ctx, so_file):
                    if not needed_so.startswith("lib") or not needed_so.endswith(".so"):
                        continue
                    needed_name = needed_so[len("lib"):-len(".so")]
                    if needed_name in selected:
                        continue
                    if not repository_ctx.path("root/lib/lib{}.so".format(needed_name)).exists:
                        # Not part of the ROOT tarball itself (e.g. a system lib already
                        # resolved via linkopts, or something with a versioned .so name that
                        # never matches this bare lib<name>.so pattern) - nothing to add.
                        continue
                    selected[needed_name] = True
                    next_frontier.append(needed_name)
            frontier = next_frontier
        root_lib_names = sorted(selected.keys())

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

# The full, unfiltered tarball - every file, not just the narrowed srcs= subset above used for
# linking. Consumed by //:katydid_release to bundle ROOT wholesale into its own root/
# subdirectory: ROOT's runtime needs a complete install layout (bin/, lib/, etc/, include/) to
# find things like etc/gitinfo.txt and dlopen()-load libCling.so by its own internal search
# logic - neither is a real ELF NEEDED dependency, so only bundling the whole tree satisfies
# them.
filegroup(
    name = "all_files",
    srcs = glob(["root/**"], allow_empty = True),
)

exports_files(["rootcling"])
""".format(srcs = repr(root_srcs), linkopts = repr(root_linkopts)))

    # Symlinked to the repository root, not referenced as root/bin/rootcling directly: keeps
    # the label @root//:rootcling short - tools/root_dictionary.bzl's _rootcling attribute
    # default references it directly.
    repository_ctx.symlink("root/bin/rootcling", "rootcling")

# No local = True, unlike system_deps.bzl's _system_libs_repo: ROOT's version is a fixed pin
# in this file, not host state that can change between builds without the file itself
# changing, so Bazel only needs to re-run this when the file changes (see the module
# docstring for why this matters).
root_repo = repository_rule(implementation = _root_repo_impl)

def _root_deps_impl(_module_ctx):
    root_repo(name = "root")

root_deps = module_extension(implementation = _root_deps_impl)
