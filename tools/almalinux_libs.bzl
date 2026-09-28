"""Provides Boost, FFTW, MatIO, TBB, xxhash, FreeType, GSL, brotli, harfbuzz, libpng, and
graphite2 for AlmaLinux 9, exposed as @almalinux_libs, fetched hermetically from pinned,
permalinked package snapshots.

AlmaLinux's live dnf repos (repo.almalinux.org) are rolling and prune a package once a newer
build supersedes it, so building against whatever dnf currently has installed isn't reproducible
months later. Every package here instead comes from a frozen, permalinked snapshot:
vault.almalinux.org for packages AlmaLinux itself ships, and dl.fedoraproject.org's EPEL archive
(the archived dl.fedoraproject.org/pub/archive/epel/, not the live dl.fedoraproject.org/pub/epel/)
for MatIO, which comes from the separate EPEL project.

rpm2cpio and cpio unpack each package; Bazel's own download_and_extract has no built-in support
for the .rpm format. rpm2cpio ships with the `rpm` package; cpio may need installing.

Boost, FFTW, and MatIO are Katydid's direct build dependencies, so both their headers and
compiled libraries are extracted and exposed as a cc_import with hdrs. The rest are needed only
because ROOT's prebuilt binaries link against them, with nothing here including their headers,
so only the compiled library is extracted and exposed as a plain filegroup.

Some packages ship their compiled library under a filename that doesn't match the SONAME a
consumer looks up at runtime - e.g. xxhash's payload is "libxxhash.so.0.8.2", with
"libxxhash.so.0" as a symlink beside it - so EXTRACTED_LIBS records the source path inside each
package next to the runtime filename to bundle it as.

A `-devel` package's own unversioned convenience symlink (e.g. boost-devel's
usr/lib64/libboost_filesystem.so) points at a target that isn't included in that package; it
only resolves once the matching runtime package (e.g. boost-filesystem) sits alongside it.
"""

# Bump this (and nowhere else) to change the AlmaLinux vault snapshot every vault.almalinux.org
# entry below is pinned against; entries with an explicit "url" aren't affected. To refresh: on
# a fresh almalinux:9 container, `dnf download <pkg>` each package, note its exact repo (`dnf
# repoquery --qf '%{reponame}'`), then find the matching
# https://vault.almalinux.org/<release>/<repo>/x86_64/os/Packages/ entry once the container's
# current rolling release has been superseded by a newer one - vault only freezes a release
# after it stops being the live one.
_ALMALINUX_VAULT_RELEASE = "9.7"

# One entry per package: either {repo, filename, sha256} (built into a vault.almalinux.org URL
# using _ALMALINUX_VAULT_RELEASE above), or {url, sha256} directly (a fully pinned URL, for a
# package not covered by that release).
RPM_DOWNLOADS = {
    # Headers only; compiled libraries come from four separate packages (see EXTRACTED_LIBS).
    "boost-devel": {
        "repo": "AppStream",
        "filename": "boost-devel-1.75.0-13.el9_7.x86_64.rpm",
        "sha256": "cae425f56361d9b186ec680493693badc8cca3d42455d3e7af816acf2cbd63a2",
    },
    "boost-filesystem": {
        "repo": "AppStream",
        "filename": "boost-filesystem-1.75.0-13.el9_7.x86_64.rpm",
        "sha256": "352d84855b2c39aff986b1a0340002a87e8490d800e2d4d36175f53c9f77be2a",
    },
    "boost-thread": {
        "repo": "AppStream",
        "filename": "boost-thread-1.75.0-13.el9_7.x86_64.rpm",
        "sha256": "1d23bf11df5e93d6e2d68fc3f5f2e0eb2d79b57e367c894d4ea43d0ac906b827",
    },
    "boost-date-time": {
        "repo": "AppStream",
        "filename": "boost-date-time-1.75.0-13.el9_7.x86_64.rpm",
        "sha256": "e88363f3aecfa295014c4ac95a49b0ecd538b556e42272a9f73673154c5dd035",
    },
    "boost-program-options": {
        "repo": "AppStream",
        "filename": "boost-program-options-1.75.0-13.el9_7.x86_64.rpm",
        "sha256": "709ac7193b267de7a8ca29f91d80d456db19e87527d244d54cf9719fe3f92956",
    },
    # Headers only; the compiled library is in fftw-libs-double.
    "fftw-devel": {
        "repo": "AppStream",
        "filename": "fftw-devel-3.3.8-12.el9.x86_64.rpm",
        "sha256": "21ded4f5da9cbfc00b200b48ba39c0f851d9b5a9c2fb978302bd7a4d30c7a020",
    },
    "fftw-libs-double": {
        "repo": "AppStream",
        "filename": "fftw-libs-double-3.3.8-12.el9.x86_64.rpm",
        "sha256": "3beed15e45dc5b33e64532da7412c243368eca5be5f113164425bb09c04da0fe",
    },
    # Headers only; the compiled library is in the plain "matio" runtime package below. From
    # EPEL (dl.fedoraproject.org), not AlmaLinux's own vault.
    #
    # dl.fedoraproject.org/pub/archive/epel/ is indexed by dated/point snapshots (9.0, 9.1, ...),
    # not a bare major version the way vault.almalinux.org is. Pinned to 9.7 to match
    # _ALMALINUX_VAULT_RELEASE above.
    "matio-devel": {
        "url": "https://dl.fedoraproject.org/pub/archive/epel/9.7/Everything/x86_64/Packages/m/matio-devel-1.5.27-1.el9.x86_64.rpm",
        "sha256": "e76e256d0cd2214c3baee90ae90875d323c52fe0e4c9a1b088b07b29b52bfeaf",
    },
    "matio": {
        "url": "https://dl.fedoraproject.org/pub/archive/epel/9.7/Everything/x86_64/Packages/m/matio-1.5.27-1.el9.x86_64.rpm",
        "sha256": "32f354c5dd66c5d9afddf987742b0b88593f0da61d7afced1ee31684d524d623",
    },
    # No headers needed, so this uses the plain runtime "tbb" package rather than tbb-devel.
    "tbb": {
        "repo": "AppStream",
        "filename": "tbb-2020.3-9.el9.x86_64.rpm",
        "sha256": "c0400e2eca46d4b54d52f9ff000fda086557867d7c46bf0ec9f23e1285bc1cb8",
    },
    "xxhash-libs": {
        "repo": "AppStream",
        "filename": "xxhash-libs-0.8.2-1.el9.x86_64.rpm",
        "sha256": "94f48dcda94673de355acc6b06dd50779fa0554b2e69f7353407bcec2ff8c344",
    },
    "freetype": {
        "repo": "BaseOS",
        "filename": "freetype-2.10.4-10.el9_5.x86_64.rpm",
        "sha256": "a727459934963abc82dc8f01a6758211b82675b6c6c3453c0f272904768ec336",
    },
    "gsl": {
        "repo": "AppStream",
        "filename": "gsl-2.6-7.el9.x86_64.rpm",
        "sha256": "3442eafbd2a62482e38be1b7932075b476d4d0651d24a14c91421fa4951c9af2",
    },
    # libharfbuzz depends on libgraphite2 (freetype is covered above). libbrotlidec depends on
    # libbrotlicommon, bundled in the same "libbrotli" package (see EXTRACTED_LIBS).
    "libbrotli": {
        "repo": "BaseOS",
        "filename": "libbrotli-1.0.9-9.el9_7.x86_64.rpm",
        "sha256": "3d24c430a1edb4d196bbec70cd59e3580421f91c8ad0c25451b9cc7130cfe66a",
    },
    "harfbuzz": {
        "repo": "BaseOS",
        "filename": "harfbuzz-2.7.4-10.el9.x86_64.rpm",
        "sha256": "1f81073019abe4176d4496723a89b55a349c31f507e96397a0b3efa7cea0ff61",
    },
    # Pinned via an explicit "url" rather than _ALMALINUX_VAULT_RELEASE's filename shape: the
    # 9.7 vault snapshot's newest libpng build is 1.6.37-12.el9_7.4 - same upstream version and
    # libpng16.so.16 soname as later builds, just an older revision.
    "libpng": {
        "url": "https://vault.almalinux.org/9.7/BaseOS/x86_64/os/Packages/libpng-1.6.37-12.el9_7.4.x86_64.rpm",
        "sha256": "d5cd1e6b0b2bfa0b66025b1ad790235af1169e02749eabff6839a3f35d2a109e",
    },
    "graphite2": {
        "repo": "BaseOS",
        "filename": "graphite2-1.3.14-9.el9.x86_64.rpm",
        "sha256": "1b8a5d4ebbeaa60dadefdb7b4c386809d349304dd658e57158f0fff36868e5e9",
    },
}

# Every compiled library this repository exposes: (package, path inside the package, runtime
# filename to bundle it as).
#
# Boost's, FFTW's, and MatIO's compiled libraries come from separate runtime packages, not
# boost-devel/fftw-devel/matio-devel: each -devel package's own usr/lib64/libboost_*.so,
# libfftw3.so, or libmatio.so entry is an unversioned convenience symlink whose target isn't
# included in that package - only the matching runtime package (e.g. boost-filesystem,
# fftw-libs-double, or plain matio) provides it.
EXTRACTED_LIBS = [
    ("boost-filesystem", "usr/lib64/libboost_filesystem.so.1.75.0", "libboost_filesystem.so.1.75.0"),
    ("boost-thread", "usr/lib64/libboost_thread.so.1.75.0", "libboost_thread.so.1.75.0"),
    ("boost-date-time", "usr/lib64/libboost_date_time.so.1.75.0", "libboost_date_time.so.1.75.0"),
    ("boost-program-options", "usr/lib64/libboost_program_options.so.1.75.0", "libboost_program_options.so.1.75.0"),
    ("fftw-libs-double", "usr/lib64/libfftw3.so.3.5.8", "libfftw3.so.3"),
    # libmatio.so.13 is a working symlink to libmatio.so.13.0.0, both present in this package.
    ("matio", "usr/lib64/libmatio.so.13", "libmatio.so.13"),
    ("tbb", "usr/lib64/libtbb.so.2", "libtbb.so.2"),
    ("xxhash-libs", "usr/lib64/libxxhash.so.0.8.2", "libxxhash.so.0"),
    ("freetype", "usr/lib64/libfreetype.so.6.17.4", "libfreetype.so.6"),
    ("gsl", "usr/lib64/libgsl.so.25.0.0", "libgsl.so.25"),
    ("gsl", "usr/lib64/libgslcblas.so.0.0.0", "libgslcblas.so.0"),
    ("libbrotli", "usr/lib64/libbrotlicommon.so.1.0.9", "libbrotlicommon.so.1"),
    ("libbrotli", "usr/lib64/libbrotlidec.so.1.0.9", "libbrotlidec.so.1"),
    ("harfbuzz", "usr/lib64/libharfbuzz.so.0.20704.0", "libharfbuzz.so.0"),
    ("libpng", "usr/lib64/libpng16.so.16.37.0", "libpng16.so.16"),
    ("graphite2", "usr/lib64/libgraphite2.so.3.2.1", "libgraphite2.so.3"),
]

def _rpm_url(info):
    if "url" in info:
        return info["url"]
    return "https://vault.almalinux.org/{release}/{repo}/x86_64/os/Packages/{filename}".format(
        release = _ALMALINUX_VAULT_RELEASE,
        repo = info["repo"],
        filename = info["filename"],
    )

def download_and_extract_rpm(repository_ctx, pkg_name):
    """Downloads pkg_name's pinned .rpm and extracts it into "<pkg_name>_extracted/".

    Args:
        repository_ctx: the calling repository_rule's repository_ctx.
        pkg_name: a key into RPM_DOWNLOADS.
    """
    info = RPM_DOWNLOADS[pkg_name]
    url = _rpm_url(info)
    rpm_path = pkg_name + ".rpm"
    repository_ctx.download(url = url, output = rpm_path, sha256 = info["sha256"])

    out_dir = pkg_name + "_extracted"
    repository_ctx.execute(["mkdir", "-p", out_dir])
    result = repository_ctx.execute([
        "sh",
        "-c",
        "rpm2cpio '{rpm}' | (cd '{out}' && cpio -idm --quiet)".format(rpm = rpm_path, out = out_dir),
    ])
    if result.return_code != 0:
        fail("Failed to extract {}: {}".format(pkg_name, result.stderr))

# A real .so starts with the 4-byte ELF magic number; anything else here is most likely a GNU ld
# linker script and needs this file's EXTRACTED_LIBS entry fixed to point at whatever real file
# it resolves to. Shells out to od/head rather than repository_ctx.read(), which assumes text
# content.
def check_is_elf_or_fail(repository_ctx, path, pkg_name, source_path):
    result = repository_ctx.execute(["sh", "-c", "head -c4 '{}' | od -An -tx1".format(path)])
    magic = result.stdout.strip().replace(" ", "")
    if magic != "7f454c46":
        fail((
            "{source} (from the {pkg} package) is not a real ELF shared library - probably a " +
            "GNU ld linker script. tools/almalinux_libs.bzl's EXTRACTED_LIBS needs updating " +
            "to point at whatever real file it resolves to."
        ).format(source = source_path, pkg = pkg_name))

def cc_import_snippet(name, so_names, hdrs_glob = [], includes = [], defines = []):
    """Builds one cc_import's worth of BUILD.bazel text.

    The aggregating target plus one component cc_import per .so, as a standalone helper rather
    than a closure, since Starlark disallows nested defs.

    Args:
        name: the aggregating cc_import's target name.
        so_names: shared library filenames to import, one component cc_import each.
        hdrs_glob: glob patterns for the aggregating cc_import's hdrs.
        includes: the aggregating cc_import's includes.
        defines: the aggregating cc_import's defines.

    Returns:
        A list of BUILD.bazel text snippets to join into the repo's BUILD.bazel.
    """
    parts = []
    component_labels = []
    for so_name in so_names:
        import_name = "_{}_import".format(so_name.replace(".", "_"))
        component_labels.append(":" + import_name)
        parts.append("""
cc_import(
    name = "{import_name}",
    shared_library = "{so_name}",
)
""".format(import_name = import_name, so_name = so_name))
    parts.append("""
cc_import(
    name = "{name}",
    hdrs = glob({hdrs_glob}, allow_empty = True),
    includes = {includes},
    defines = {defines},
    deps = {component_labels},
)
""".format(
        name = name,
        hdrs_glob = repr(hdrs_glob),
        includes = repr(includes),
        defines = repr(defines),
        component_labels = repr(component_labels),
    ))
    return parts

# Runtime-only filenames ROOT's prebuilt binaries need, exposed as a plain filegroup: no headers,
# no cc_import, since nothing here builds against them directly.
ROOT_RUNTIME_EXTRA_LIBS = [
    "libtbb.so.2",
    "libxxhash.so.0",
    "libfreetype.so.6",
    "libgsl.so.25",
    "libgslcblas.so.0",
    "libbrotlicommon.so.1",
    "libbrotlidec.so.1",
    "libharfbuzz.so.0",
    "libpng16.so.16",
    "libgraphite2.so.3",
]

def _almalinux_libs_repo_impl(repository_ctx):
    for pkg_name in RPM_DOWNLOADS:
        download_and_extract_rpm(repository_ctx, pkg_name)

    build_file_parts = [
        'load("@rules_cc//cc:cc_import.bzl", "cc_import")',
        'package(default_visibility = ["//visibility:public"])',
    ]

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
        # Matches the CMake build's add_definitions(-DFFTW_FOUND): Katydid's code checks
        # #ifdef FFTW_FOUND to decide whether real FFTW is available.
        defines = ["FFTW_FOUND"],
    ))
    build_file_parts.extend(cc_import_snippet(
        name = "matio",
        so_names = ["libmatio.so.13"],
        hdrs_glob = ["matio-devel_extracted/usr/include/matio.h", "matio-devel_extracted/usr/include/matio_pubconf.h"],
        includes = ["matio-devel_extracted/usr/include"],
    ))

    # No cc_import, no hdrs: ROOT's prebuilt binaries just need the plain .so present at runtime.
    build_file_parts.append("""
filegroup(
    name = "root_runtime_extra_libs",
    srcs = {srcs},
)
""".format(srcs = repr(ROOT_RUNTIME_EXTRA_LIBS)))

    repository_ctx.file("BUILD.bazel", "\n".join(build_file_parts))

_almalinux_libs_repo = repository_rule(implementation = _almalinux_libs_repo_impl)

def _almalinux_libs_impl(_module_ctx):
    _almalinux_libs_repo(name = "almalinux_libs")

almalinux_libs = module_extension(implementation = _almalinux_libs_impl)
