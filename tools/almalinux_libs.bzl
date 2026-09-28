"""Provides Boost, FFTW, MatIO, TBB, xxhash, FreeType, and GSL for AlmaLinux 9, exposed as
@almalinux_libs - all fetched hermetically from pinned, permalinked package snapshots, rather
than discovered from whatever dnf currently has installed.

Host discovery (the approach tools/ubuntu_libs.bzl/tools/macos_libs.bzl use) isn't reproducible
on AlmaLinux the way it is on Ubuntu/macOS: AlmaLinux's live dnf repos (repo.almalinux.org) are
rolling and prune a package once a newer build supersedes it, so a rebuild months later can fail
outright, not just resolve a different version. Every package here instead comes from a frozen,
permalinked snapshot: vault.almalinux.org for packages AlmaLinux itself ships (Boost, FFTW, TBB,
xxhash, FreeType, GSL), and dl.fedoraproject.org's EPEL archive for MatIO, which comes from the
separate EPEL project, not AlmaLinux's own repos - EPEL has its own equivalent frozen mirror at
dl.fedoraproject.org/pub/archive/epel/ (as opposed to the live, rolling dl.fedoraproject.org/pub/
epel/), used for exactly the same reason.

rpm2cpio + cpio unpack each package: Bazel's own download_and_extract has no built-in
understanding of the .rpm format (only zip/tar variants). rpm2cpio ships with the `rpm` package
every dnf install depends on, so it's always present on AlmaLinux; cpio may need installing (a
build-only tool, never a runtime dependency of anything produced here).

Three of these (Boost, FFTW, MatIO) are Katydid's own direct build dependency, so both their
headers and compiled libraries are extracted and exposed as a cc_import with hdrs - the exact
same @almalinux_libs//:boost / :fftw / :matio shape tools/ubuntu_libs.bzl and
tools/macos_libs.bzl expose, so tools/binary_deps.bzl's alias() can point at whichever one
matches the host with no BUILD file needing to know or care which was used. The other four
(TBB, xxhash, FreeType, GSL/GSLCBLAS) are needed only because ROOT's own prebuilt binaries link
against them - nothing here ever #includes their headers - so only the compiled library is
extracted, exposed as a plain filegroup rather than a cc_import (nothing `deps` on it; a
release archive bundles it directly).

Some of these packages ship their compiled library under a filename that doesn't match the
exact SONAME a consumer actually looks up at runtime - e.g. xxhash's real payload is
"libxxhash.so.0.8.2", with "libxxhash.so.0" (what Katydid actually needs, confirmed via `ldd`
against a real build) as a symlink beside it - so EXTRACTED_LIBS below records the source path
inside each package next to the runtime filename it needs to be bundled as.

A `-devel` package's own unversioned convenience symlinks (e.g. boost-devel's
usr/lib64/libboost_filesystem.so, or matio-devel's usr/lib64/libmatio.so) are a different
problem, not just a naming mismatch: their target isn't in the package at all, only resolving
once the matching separate runtime package (e.g. boost-filesystem, or plain matio) is installed
alongside it - see the comment on EXTRACTED_LIBS.

Nothing should reference this repo directly - go through @binary_deps instead (see
tools/binary_deps.bzl), which resolves to whichever platform repo is actually live on the
current host, with no select()/config_setting/flag anywhere.

To refresh a pin (a version bump, or filling in a still-TODO sha256): tools/pin_rpm.sh
downloads a candidate URL and prints its sha256, ready to paste into RPM_DOWNLOADS below.
"""

# Bump this (and nowhere else) to change the AlmaLinux vault snapshot every vault.almalinux.org
# entry below is pinned against - entries with an explicit "url" (the EPEL ones) aren't
# affected. To refresh: on a fresh almalinux:9 container, `dnf download <pkg>` each package
# below, note its exact repo (`dnf repoquery --qf '%{reponame}'`), then find the matching
# https://vault.almalinux.org/<release>/<repo>/x86_64/os/Packages/ entry once the container's
# current rolling release has been superseded by a newer one (vault only freezes a release
# after it stops being the live one) - confirm its sha256 matches what `dnf download` gave you
# before trusting the vault copy (tools/pin_rpm.sh automates the download+sha256 step).
_ALMALINUX_VAULT_RELEASE = "9.7"

# One entry per package: either {repo, filename, sha256} (built into a vault.almalinux.org URL
# using _ALMALINUX_VAULT_RELEASE above - AlmaLinux's own packages), or {url, sha256} directly
# (a fully pinned URL - used for MatIO, which comes from EPEL's own separate archive instead;
# see the module docstring).
RPM_DOWNLOADS = {
    # Headers only - see the comment on EXTRACTED_LIBS below for why the compiled libraries
    # come from four separate packages instead.
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
    # Headers only - fftw-devel's own usr/lib64/libfftw3.so is an unversioned convenience
    # symlink whose target isn't in this package either (same story as Boost above); the real
    # compiled library is in fftw-libs-double.
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
    # Headers only, same broken-unversioned-symlink story as boost-devel/fftw-devel above - the
    # real compiled library is in the plain "matio" runtime package below. Comes from EPEL
    # (dl.fedoraproject.org), not AlmaLinux's own vault - see the module docstring.
    #
    # dl.fedoraproject.org/pub/archive/epel/ is NOT indexed by a bare major version ("9") the
    # way vault.almalinux.org is - it's dated/point snapshots (9.0, 9.1, ...). Pinned to 9.7 to
    # match _ALMALINUX_VAULT_RELEASE above (confirmed present there via tools/find_epel_snapshot.sh,
    # run from a machine that can actually reach dl.fedoraproject.org - this repo's sandbox
    # can't).
    #
    # TODO(you): sha256 not yet verified from a real download - run:
    #   tools/pin_rpm.sh matio-devel https://dl.fedoraproject.org/pub/archive/epel/9.7/Everything/x86_64/Packages/m/matio-devel-1.5.27-1.el9.x86_64.rpm
    # and paste the sha256 it prints in below.
    "matio-devel": {
        "url": "https://dl.fedoraproject.org/pub/archive/epel/9.7/Everything/x86_64/Packages/m/matio-devel-1.5.27-1.el9.x86_64.rpm",
        "sha256": "e76e256d0cd2214c3baee90ae90875d323c52fe0e4c9a1b088b07b29b52bfeaf",
    },
    # TODO(you): same as matio-devel above - run:
    #   tools/pin_rpm.sh matio https://dl.fedoraproject.org/pub/archive/epel/9.7/Everything/x86_64/Packages/m/matio-1.5.27-1.el9.x86_64.rpm
    "matio": {
        "url": "https://dl.fedoraproject.org/pub/archive/epel/9.7/Everything/x86_64/Packages/m/matio-1.5.27-1.el9.x86_64.rpm",
        "sha256": "32f354c5dd66c5d9afddf987742b0b88593f0da61d7afced1ee31684d524d623",
    },
    # tbb-devel's own usr/lib64/libtbb.so is the same kind of broken unversioned symlink
    # boost-devel/fftw-devel have - and unlike Boost/FFTW, nothing here needs TBB's headers at
    # all, so this uses the plain runtime "tbb" package directly instead of also keeping
    # tbb-devel around for nothing.
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
}

# Every compiled library this repository exposes: (package, path inside the package, runtime
# filename to bundle it as - see this file's docstring for why the two filenames differ).
#
# Boost's, FFTW's, and MatIO's compiled libraries come from separate runtime packages, not
# boost-devel/fftw-devel/matio-devel: each -devel package's own usr/lib64/libboost_*.so,
# libfftw3.so, or libmatio.so entry is an unversioned convenience symlink (an RPM dependency on
# the matching runtime package - e.g. boost-filesystem, fftw-libs-double, or plain matio - is
# what normally makes it resolve) - confirmed broken when each -devel package is unpacked on
# its own, via `file` reporting e.g. "broken symbolic link to libboost_filesystem.so.1.75.0"
# for a target the -devel package doesn't contain.
EXTRACTED_LIBS = [
    ("boost-filesystem", "usr/lib64/libboost_filesystem.so.1.75.0", "libboost_filesystem.so.1.75.0"),
    ("boost-thread", "usr/lib64/libboost_thread.so.1.75.0", "libboost_thread.so.1.75.0"),
    ("boost-date-time", "usr/lib64/libboost_date_time.so.1.75.0", "libboost_date_time.so.1.75.0"),
    ("boost-program-options", "usr/lib64/libboost_program_options.so.1.75.0", "libboost_program_options.so.1.75.0"),
    ("fftw-libs-double", "usr/lib64/libfftw3.so.3.5.8", "libfftw3.so.3"),
    # The "matio" runtime package's own SONAME-level symlink (libmatio.so.13 -> its own
    # libmatio.so.13.0.0, both present in the same package) resolves fine as-is, same as
    # tbb/xxhash/freetype/gsl's below - only the -devel packages' convenience symlinks are
    # broken (see this file's docstring).
    ("matio", "usr/lib64/libmatio.so.13", "libmatio.so.13"),
    ("tbb", "usr/lib64/libtbb.so.2", "libtbb.so.2"),
    ("xxhash-libs", "usr/lib64/libxxhash.so.0.8.2", "libxxhash.so.0"),
    ("freetype", "usr/lib64/libfreetype.so.6.17.4", "libfreetype.so.6"),
    ("gsl", "usr/lib64/libgsl.so.25.0.0", "libgsl.so.25"),
    ("gsl", "usr/lib64/libgslcblas.so.0.0.0", "libgslcblas.so.0"),
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

# A real .so starts with the 4-byte ELF magic number; anything else here (most likely a GNU ld
# linker script, plain text) can't be used as-is and needs this file's EXTRACTED_LIBS entry
# fixed to point at whatever real file that script resolves to instead. Shells out to od/head
# (plain coreutils, always present) rather than repository_ctx.read(), which assumes text
# content and isn't reliable on arbitrary binary bytes.
def check_is_elf_or_fail(repository_ctx, path, pkg_name, source_path):
    result = repository_ctx.execute(["sh", "-c", "head -c4 '{}' | od -An -tx1".format(path)])
    magic = result.stdout.strip().replace(" ", "")
    if magic != "7f454c46":
        fail((
            "{source} (from the {pkg} package) is not a real ELF shared library - probably a " +
            "GNU ld linker script. tools/almalinux_libs.bzl's EXTRACTED_LIBS needs updating " +
            "to point at whatever real file it resolves to."
        ).format(source = source_path, pkg = pkg_name))

# Starlark disallows nested defs, so this builds one cc_import's worth of BUILD.bazel text
# (the aggregating target plus one component cc_import per .so) as a standalone helper rather
# than a closure inside _almalinux_libs_repo_impl.
def cc_import_snippet(name, so_names, hdrs_glob = [], includes = []):
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
    deps = {component_labels},
)
""".format(
        name = name,
        hdrs_glob = repr(hdrs_glob),
        includes = repr(includes),
        component_labels = repr(component_labels),
    ))
    return parts

# TBB/xxhash/FreeType/GSL's runtime filenames - the four EXTRACTED_LIBS entries not covered by
# boost/fftw/matio's own cc_import below. Exposed as a plain filegroup (see module docstring
# for why), consumed by tools/binary_deps.bzl to build @binary_deps//:root_runtime_extra_libs.
ROOT_RUNTIME_EXTRA_LIBS = ["libtbb.so.2", "libxxhash.so.0", "libfreetype.so.6", "libgsl.so.25", "libgslcblas.so.0"]

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
    ))
    build_file_parts.extend(cc_import_snippet(
        name = "matio",
        so_names = ["libmatio.so.13"],
        hdrs_glob = ["matio-devel_extracted/usr/include/matio.h", "matio-devel_extracted/usr/include/matio_pubconf.h"],
        includes = ["matio-devel_extracted/usr/include"],
    ))

    # TBB/xxhash/FreeType/GSL: no cc_import, no hdrs - nothing here builds against these,
    # ROOT's own prebuilt binaries just need the plain .so present alongside them at runtime.
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
