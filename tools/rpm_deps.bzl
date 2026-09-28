"""Helpers for fetching Boost, FFTW, TBB, xxhash, FreeType, and GSL from pinned AlmaLinux 9
.rpm packages.

This file has no repository rule or module extension of its own - it's a library of helpers
that tools/system_deps.bzl's @system_libs repository rule calls directly, from a branch it
takes only when linux_distro_id(repository_ctx) == "almalinux" (see that file). AlmaLinux's
own dnf repos are rolling and prune a package once a newer build supersedes it, so - unlike
apt or Homebrew - dnf-based host discovery there isn't reproducible; a hermetic fetch of
pinned packages is used instead, while still exposing the exact same @system_libs//:boost and
@system_libs//:fftw labels every other platform uses.

Each package is downloaded from a frozen vault.almalinux.org snapshot (not the rolling
repo.almalinux.org, which prunes a package once a newer build supersedes it) and unpacked with
rpm2cpio + cpio: Bazel's own download_and_extract has no built-in understanding of the .rpm
format (only zip/tar variants). rpm2cpio ships with the `rpm` package every dnf install
depends on, so it's always present on AlmaLinux; cpio may need installing (a build-only tool,
never a runtime dependency of anything produced here).

Two of these (Boost, FFTW) are Katydid's own direct build dependency, so both their headers
and compiled libraries are extracted and exposed as a cc_import with hdrs. The other four (TBB,
xxhash, FreeType, GSL/GSLCBLAS) are needed only because ROOT's own prebuilt binaries link
against them - nothing here ever #includes their headers - so only the compiled library is
extracted, exposed as a plain filegroup rather than a cc_import (nothing `deps` on it; a
release archive bundles it directly).

Some of these packages ship their compiled library under a filename that doesn't match the
exact SONAME a consumer actually looks up at runtime - e.g. xxhash's real payload is
"libxxhash.so.0.8.2", with "libxxhash.so.0" (what Katydid actually needs, confirmed via `ldd`
against a real build) as a symlink beside it - so EXTRACTED_LIBS below records the source path
inside each package next to the runtime filename it needs to be bundled as.

A `-devel` package's own unversioned convenience symlinks (e.g. boost-devel's
usr/lib64/libboost_filesystem.so) are a different problem, not just a naming mismatch: their
target isn't in the package at all, only resolving once the matching separate runtime package
(e.g. boost-filesystem, or fftw-libs-double for fftw-devel) is installed alongside it - see the
comment on EXTRACTED_LIBS.
"""

# Bump this (and nowhere else) to change the AlmaLinux vault snapshot every package below is
# pinned against. To refresh: on a fresh almalinux:9 container, `dnf download <pkg>` each
# package below, note its exact repo (`dnf repoquery --qf '%{reponame}'`), then find the
# matching https://vault.almalinux.org/<release>/<repo>/x86_64/os/Packages/ entry once the
# container's current rolling release has been superseded by a newer one (vault only freezes a
# release after it stops being the live one) - confirm its sha256 matches what `dnf download`
# gave you before trusting the vault copy.
_ALMALINUX_VAULT_RELEASE = "9.7"

# One exact {repo, filename, sha256} per package.
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
# Boost's and FFTW's compiled libraries come from separate runtime packages, not boost-devel/
# fftw-devel: each -devel package's own usr/lib64/libboost_*.so or libfftw3.so entry is an
# unversioned convenience symlink (an RPM dependency on the matching runtime package - e.g.
# boost-filesystem, or fftw-libs-double - is what normally makes it resolve) - confirmed broken
# when each -devel package is unpacked on its own, via `file` reporting e.g. "broken symbolic
# link to libboost_filesystem.so.1.75.0" for a target the -devel package doesn't contain.
EXTRACTED_LIBS = [
    ("boost-filesystem", "usr/lib64/libboost_filesystem.so.1.75.0", "libboost_filesystem.so.1.75.0"),
    ("boost-thread", "usr/lib64/libboost_thread.so.1.75.0", "libboost_thread.so.1.75.0"),
    ("boost-date-time", "usr/lib64/libboost_date_time.so.1.75.0", "libboost_date_time.so.1.75.0"),
    ("boost-program-options", "usr/lib64/libboost_program_options.so.1.75.0", "libboost_program_options.so.1.75.0"),
    ("fftw-libs-double", "usr/lib64/libfftw3.so.3.5.8", "libfftw3.so.3"),
    ("tbb", "usr/lib64/libtbb.so.2", "libtbb.so.2"),
    ("xxhash-libs", "usr/lib64/libxxhash.so.0.8.2", "libxxhash.so.0"),
    ("freetype", "usr/lib64/libfreetype.so.6.17.4", "libfreetype.so.6"),
    ("gsl", "usr/lib64/libgsl.so.25.0.0", "libgsl.so.25"),
    ("gsl", "usr/lib64/libgslcblas.so.0.0.0", "libgslcblas.so.0"),
]

def download_and_extract_rpm(repository_ctx, pkg_name):
    info = RPM_DOWNLOADS[pkg_name]
    url = "https://vault.almalinux.org/{release}/{repo}/x86_64/os/Packages/{filename}".format(
        release = _ALMALINUX_VAULT_RELEASE,
        repo = info["repo"],
        filename = info["filename"],
    )
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
            "GNU ld linker script. tools/rpm_deps.bzl's EXTRACTED_LIBS needs updating to " +
            "point at whatever real file it resolves to."
        ).format(source = source_path, pkg = pkg_name))

# Starlark disallows nested defs, so this builds one cc_import's worth of BUILD.bazel text
# (the aggregating target plus one component cc_import per .so) as a standalone helper rather
# than a closure inside tools/system_deps.bzl's repository rule impl.
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

# The four AlmaLinux-only formula/runtime-file names not covered by boost/fftw's own
# cc_import above - see this file's docstring for why these four are a bare filegroup rather
# than a cc_import. Read by tools/system_deps.bzl to build @system_libs//:root_runtime_extra_libs.
ROOT_RUNTIME_EXTRA_LIBS = ["libtbb.so.2", "libxxhash.so.0", "libfreetype.so.6", "libgsl.so.25", "libgslcblas.so.0"]
