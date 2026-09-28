"""Defines katydid_cc_test, the rule to use for a Katydid C++ test in this package."""

load("@rules_cc//cc:cc_binary.bzl", "cc_binary")
load("//Source/Executables/Main:root_include_path_launcher.bzl", "root_include_path_test_launcher")

# Relative labels here resolve against whichever package actually calls this macro (Validation's),
# not this .bzl file's package - the genrules they name are defined in that BUILD file.
_PCM_DATA = [
    ":CicadaDict_pcm_local_copy",
    ":IODict_pcm_local_copy",
]

def katydid_cc_test(name, srcs, deps, dynamic_deps, data = []):
    """Defines one Katydid C++ test, named name.

    Args:
        name: the test's public name.
        srcs: the test's source files.
        deps: the test's dependencies.
        dynamic_deps: the test's dynamic library dependencies.
        data: runtime data files for the test.
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
