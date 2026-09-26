"""Defines katydid_validation_test, a macro wrapping one Validation test in the
ROOT_INCLUDE_PATH launcher unconditionally. See BUILD.bazel's own top comment for why.
"""

load("@rules_cc//cc:cc_binary.bzl", "cc_binary")
load("//Source/Executables/Main:root_include_path_launcher.bzl", "root_include_path_test_launcher")

# Relative labels here resolve against whichever package actually calls this macro (Validation's),
# not this .bzl file's package - the genrules they name are defined in that BUILD file.
_PCM_DATA = [
    ":CicadaDict_pcm_local_copy",
    ":IODict_pcm_local_copy",
]

def katydid_validation_test(name, srcs, deps, dynamic_deps, data = []):
    """Defines one Validation test, wrapped unconditionally in the ROOT_INCLUDE_PATH launcher.

    The real binary is a testonly cc_binary named name + "_bin": running it directly is never
    valid (ROOT_INCLUDE_PATH must be set before it starts - see root_include_path_launcher.bzl's
    docstring), so it's a cc_binary rather than a cc_test. The wrapper sh_test, named plain
    name, is the actual test target and what `bazel test`/`bazel run` should be given.

    Args:
        name: the test's public name; also the name of the generated sh_test wrapper.
        srcs: passed straight to the underlying cc_binary.
        deps: passed straight to the underlying cc_binary.
        dynamic_deps: passed straight to the underlying cc_binary.
        data: passed straight to the underlying cc_binary.
    """
    bin_name = name + "_bin"
    cc_binary(
        name = bin_name,
        testonly = True,
        srcs = srcs,
        data = data,
        dynamic_deps = dynamic_deps,
        deps = deps,
    )
    root_include_path_test_launcher(
        name = name,
        real_bin_label = ":" + bin_name,
        pcm_data = _PCM_DATA,
    )
