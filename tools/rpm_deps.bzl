"""Fetches Boost, FFTW, TBB, xxhash, FreeType, and GSL from pinned AlmaLinux 9 .rpm packages,
exposed as @rpm_deps.

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

Every one of these packages ships its compiled library under an unversioned or
partially-versioned filename (e.g. plain "libboost_filesystem.so", or "libxxhash.so.0" beside
the fuller "libxxhash.so.0.8.2"), which does not always match the exact SONAME a consumer
actually looks up at runtime (confirmed via `ldd` against a real build: e.g. Katydid needs
"libboost_filesystem.so.1.75.0", not the bare "libboost_filesystem.so" this package ships) -
_EXTRACTED_LIBS below records the source path inside each package next to the runtime filename
it needs to be bundled as.

Usage from a BUILD file: deps = ["@rpm_deps//:boost", "@rpm_deps//:fftw"]
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
_RPM_DOWNLOADS = {
    "boost-devel": {
        "repo": "AppStream",
        "filename": "boost-devel-1.75.0-13.el9_7.x86_64.rpm",
        "sha256": "cae425f56361d9b186ec680493693badc8cca3d42455d3e7af816acf2cbd63a2",
    },
    "fftw-devel": {
        "repo": "AppStream",
        "filename": "fftw-devel-3.3.8-12.el9.x86_64.rpm",
        "sha256": "21ded4f5da9cbfc00b200b48ba39c0f851d9b5a9c2fb978302bd7a4d30c7a020",
    },
    "tbb-devel": {
        "repo": "AppStream",
        "filename": "tbb-devel-2020.3-9.el9.x86_64.rpm",
        "sha256": "f5b356364d8e02331919d69c98602389829c7096c92c02e14f17b1ff1f61f56d",
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
_EXTRACTED_LIBS = [
    ("boost-devel", "usr/lib64/libboost_filesystem.so", "libboost_filesystem.so.1.75.0"),
    ("boost-devel", "usr/lib64/libboost_thread.so", "libboost_thread.so.1.75.0"),
    ("boost-devel", "usr/lib64/libboost_date_time.so", "libboost_date_time.so.1.75.0"),
    ("boost-devel", "usr/lib64/libboost_program_options.so", "libboost_program_options.so.1.75.0"),
    ("fftw-devel", "usr/lib64/libfftw3.so", "libfftw3.so.3"),
    ("tbb-devel", "usr/lib64/libtbb.so", "libtbb.so.2"),
    ("xxhash-libs", "usr/lib64/libxxhash.so.0.8.2", "libxxhash.so.0"),
    ("freetype", "usr/lib64/libfreetype.so.6.17.4", "libfreetype.so.6"),
    ("gsl", "usr/lib64/libgsl.so.25.0.0", "libgsl.so.25"),
    ("gsl", "usr/lib64/libgslcblas.so.0.0.0", "libgslcblas.so.0"),
]

def _download_and_extract_rpm(repository_ctx, pkg_name):
    info = _RPM_DOWNLOADS[pkg_name]
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
# linker script, plain text) can't be used as-is and needs this file's _EXTRACTED_LIBS entry
# fixed to point at whatever real file that script resolves to instead. Shells out to od/head
# (plain coreutils, always present) rather than repository_ctx.read(), which assumes text
# content and isn't reliable on arbitrary binary bytes.
def _check_is_elf_or_fail(repository_ctx, path, pkg_name, source_path):
    result = repository_ctx.execute(["sh", "-c", "head -c4 '{}' | od -An -tx1".format(path)])
    magic = result.stdout.strip().replace(" ", "")
    if magic != "7f454c46":
        fail((
            "{source} (from the {pkg} package) is not a real ELF shared library - probably a " +
            "GNU ld linker script. tools/rpm_deps.bzl's _EXTRACTED_LIBS needs updating to " +
            "point at whatever real file it resolves to."
        ).format(source = source_path, pkg = pkg_name))

# Starlark disallows nested defs, so this builds one cc_import's worth of BUILD.bazel text
# (the aggregating target plus one component cc_import per .so) as a standalone helper rather
# than a closure inside _rpm_deps_repo_impl.
def _cc_import_snippet(name, so_names, hdrs_glob = [], includes = []):
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

def _rpm_deps_repo_impl(repository_ctx):
    for pkg_name in _RPM_DOWNLOADS:
        _download_and_extract_rpm(repository_ctx, pkg_name)

    build_file_parts = [
        'load("@rules_cc//cc:cc_import.bzl", "cc_import")',
        'package(default_visibility = ["//visibility:public"])',
    ]

    for pkg_name, source_path, runtime_name in _EXTRACTED_LIBS:
        src = "{}_extracted/{}".format(pkg_name, source_path)
        _check_is_elf_or_fail(repository_ctx, src, pkg_name, source_path)
        repository_ctx.symlink(src, runtime_name)

    build_file_parts.extend(_cc_import_snippet(
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
    build_file_parts.extend(_cc_import_snippet(
        name = "fftw",
        so_names = ["libfftw3.so.3"],
        hdrs_glob = ["fftw-devel_extracted/usr/include/fftw3.h"],
        includes = ["fftw-devel_extracted/usr/include"],
    ))

    # TBB/xxhash/FreeType/GSL: no cc_import, no hdrs - nothing here builds against these,
    # ROOT's own prebuilt binaries just need the plain .so present alongside them at runtime.
    build_file_parts.append("""
filegroup(
    name = "root_runtime_extra_libs",
    srcs = ["libtbb.so.2", "libxxhash.so.0", "libfreetype.so.6", "libgsl.so.25", "libgslcblas.so.0"],
)
""")

    repository_ctx.file("BUILD.bazel", "\n".join(build_file_parts))

_rpm_deps_repo = repository_rule(implementation = _rpm_deps_repo_impl)

def _rpm_deps_impl(_module_ctx):
    _rpm_deps_repo(name = "rpm_deps")

rpm_deps = module_extension(implementation = _rpm_deps_impl)
