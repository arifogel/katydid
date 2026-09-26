"""Generates a wrapper that sets ROOT_INCLUDE_PATH before the real binary/test it wraps starts."""

load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load("@rules_shell//shell:sh_test.bzl", "sh_test")

# Default PCM data for callers in this package (Source/Executables/Main), where these copies
# are defined locally. These are package-relative labels, so a caller in another package (see
# root_include_path_test_launcher, used from Source/Executables/Validation) must pass its own
# pcm_data explicitly, pointing at its own local copies instead.
_DEFAULT_PCM_DATA = [
    ":CicadaDict_pcm_local_copy",
    ":IODict_pcm_local_copy",
    ":UtilityDict_pcm_local_copy",
]

def _root_include_path_wrapper(name, real_bin_label, pcm_data, wrapper_rule, testonly):
    """Shared implementation behind root_include_path_launcher/root_include_path_test_launcher.

    libCore.so is a dependency of every Katydid module .so (katydid_io, katydid_utility,
    etc.); per the ELF spec, a shared object's dependencies' constructors run before its own.
    So libCore.so's constructor always runs before any code of ours and reads/caches
    ROOT_INCLUDE_PATH then. A value set from inside the process, however early, is never
    seen. It must be set externally, before the process starts.

    real_bin_label's path is baked into the generated script via Bazel's $(rlocationpath ...)
    expansion at build time: a rename or move of real_bin_label is a build-time break, not a
    silent one. $(rlocationpath ...), not $(location ...): the former already includes the
    repository-qualified prefix rlocation expects, so the script calls rlocation on it
    directly with no extra path work.

    use_bash_launcher = True initializes the runfiles library. deps on the runfiles library
    itself is also required: use_bash_launcher's generated launcher looks for the library at
    a path this deps entry provides, but does not add the dependency itself.

    wrapper_rule is sh_binary or sh_test: the wrapper execs into real_bin_label without
    forking, so the real binary's own exit code (and, for a test, pass/fail) propagates to
    Bazel directly through the wrapper either way.

    testonly must be True whenever real_bin_label is itself testonly (any cc_test): sh_test
    already defaults testonly to True on its own, but the intermediate genrule below is not a
    "*_test"-named rule, so it gets no such default and needs it set explicitly, or a plain
    `bazel build //...` refuses to analyze it ("non-test target ... depends on testonly
    target ... and doesn't have testonly attribute set").

    Args:
        name: name of the generated sh_binary/sh_test.
        real_bin_label: label of the real binary/test this wraps (e.g. ":Katydid_bin").
        pcm_data: PCM local-copy genrule labels this wraps also needs as data, so Cling finds
            them next to the real, exec'd binary (see BUILD.bazel's own comment on those
            genrules).
        wrapper_rule: sh_binary or sh_test.
        testonly: whether real_bin_label is itself testonly.
    """
    genrule_name = name + "_launcher_gen"
    native.genrule(
        name = genrule_name,
        testonly = testonly,
        srcs = [
            real_bin_label,
            "@cicada//:Library/_CROOTData.hh",
        ],
        outs = [name + "_launcher_gen.sh"],
        # $ meant to stay literal at the script's own runtime (not Bazel's genrule build
        # time) is doubled ($$) per Bazel's genrule cmd escaping rules, including the final
        # "$@" (arg forwarding): $$@ survives as a literal $@ rather than colliding with
        # genrule's own bare $@ token for its output file, since Bazel's $$ escaping is a
        # single left-to-right pass that takes precedence over interpreting what follows.
        cmd = """cat > $@ << 'LAUNCHER_EOF'
#!/usr/bin/env bash
REAL_BIN="$$(rlocation "$(rlocationpath """ + real_bin_label + """)")"
CROOT_DATA_HH="$$(rlocation "$(rlocationpath @cicada//:Library/_CROOTData.hh)")"
CROOT_DATA_DIR="$$(dirname "$${CROOT_DATA_HH}")"

# Append to any pre-existing ROOT_INCLUDE_PATH rather than replacing it.
if [[ -n "$${ROOT_INCLUDE_PATH:-}" ]]; then
  export ROOT_INCLUDE_PATH="$${ROOT_INCLUDE_PATH}:$${CROOT_DATA_DIR}"
else
  export ROOT_INCLUDE_PATH="$${CROOT_DATA_DIR}"
fi

exec "$${REAL_BIN}" "$$@"
LAUNCHER_EOF
chmod +x $@
""",
    )

    # data is needed here so these files are part of this target's own runfiles: Cling looks
    # for them directly alongside the running binary.
    #
    # @cicada//:Library/_CROOTData.hh, not a local copy: ROOT_INCLUDE_PATH (set above) is a
    # general search path, not tied to any directory, so the original file works.
    wrapper_rule(
        name = name,
        testonly = testonly,
        srcs = [":" + genrule_name],
        data = [
            real_bin_label,
            "@cicada//:Library/_CROOTData.hh",
        ] + pcm_data,
        use_bash_launcher = True,
        deps = ["@rules_shell//shell/runfiles"],
    )

def root_include_path_launcher(name, real_bin_label, pcm_data = _DEFAULT_PCM_DATA):
    """Sets ROOT_INCLUDE_PATH before real_bin_label's own process starts, then execs it.

    Args:
        name: name of the generated sh_binary.
        real_bin_label: label of the real binary this wraps (e.g. ":Katydid_bin").
        pcm_data: see _root_include_path_wrapper. Defaults to this package's own local copies.
    """
    _root_include_path_wrapper(name, real_bin_label, pcm_data, sh_binary, testonly = False)

def root_include_path_test_launcher(name, real_bin_label, pcm_data):
    """Test counterpart of root_include_path_launcher: wraps a cc_test as a real sh_test.

    Intended to wrap every Validation cc_test unconditionally, not just ones already known to
    touch Cicada's ROOT dictionary at runtime: harmless for a test that doesn't need it, and
    removes the need to reason case-by-case about which ones do (see
    Source/Executables/Validation/BUILD.bazel's own top comment).

    Args:
        name: name of the generated sh_test.
        real_bin_label: label of the real cc_test this wraps (e.g. ":TestVector_bin").
        pcm_data: see _root_include_path_wrapper. No default: these are package-relative
            labels defined in the calling package (e.g. Validation's own local PCM copies),
            not this one.
    """
    _root_include_path_wrapper(name, real_bin_label, pcm_data, sh_test, testonly = True)
