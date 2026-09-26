"""Defines katydid_validation_test, a macro wrapping one Validation cc_test in the
ROOT_INCLUDE_PATH launcher unconditionally. See BUILD.bazel's own top comment for why.
"""

load("@rules_cc//cc:cc_test.bzl", "cc_test")
load("//Source/Executables/Main:root_include_path_launcher.bzl", "root_include_path_test_launcher")

# Relative labels here resolve against whichever package actually calls this macro (Validation's
# own), not this .bzl file's own package - the genrules they name are defined in that BUILD file.
_PCM_DATA = [
    ":CicadaDict_pcm_local_copy",
    ":IODict_pcm_local_copy",
]

def katydid_validation_test(name, srcs, deps, dynamic_deps, data = []):
    """Defines one Validation test, wrapped unconditionally in the ROOT_INCLUDE_PATH launcher.

    The real cc_test is named name + "_bin" and tagged "manual" (so `bazel test //...` doesn't
    also run it unwrapped, double-counting it); the wrapper sh_test, named plain name, is what
    `bazel test`/`bazel run` should always be given.

    Args:
        name: the test's public name; also the name of the generated sh_test wrapper.
        srcs: passed straight to the underlying cc_test.
        deps: passed straight to the underlying cc_test.
        dynamic_deps: passed straight to the underlying cc_test.
        data: passed straight to the underlying cc_test.
    """
    bin_name = name + "_bin"
    cc_test(
        name = bin_name,
        srcs = srcs,
        data = data,
        dynamic_deps = dynamic_deps,
        deps = deps,
        tags = ["manual"],
    )
    root_include_path_test_launcher(
        name = name,
        real_bin_label = ":" + bin_name,
        pcm_data = _PCM_DATA,
    )
