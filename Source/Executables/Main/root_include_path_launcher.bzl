"""Generates a wrapper that sets ROOT_INCLUDE_PATH before the real binary/test it wraps starts."""

load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load("@rules_shell//shell:sh_test.bzl", "sh_test")

# Default PCM data for callers in this package (Source/Executables/Main), where these copies
# are defined locally. Package-relative labels, so a caller elsewhere (see
# root_include_path_test_launcher, used from Source/Executables/Validation) must pass pcm_data
# explicitly, pointing at its local copies instead.
_DEFAULT_PCM_DATA = [
    ":CicadaDict_pcm_local_copy",
    ":IODict_pcm_local_copy",
    ":UtilityDict_pcm_local_copy",
]

# Every header CicadaDict's dictionary payload #includes (see
# third_party/cicada/BUILD.cicada.bazel's root_dictionary() call for the authoritative list),
# not just _CROOTData.hh. Cling's autoload only needs _CROOTData.hh's FileEntry, but the
# lookup here always falls back (non-fatally) to the embedded payload text, whose
# #include "CMemberVariables.hh" (and the other #includes) still need to resolve through
# ROOT_INCLUDE_PATH. Declaring only _CROOTData.hh as data leaves the rest of Cicada's Library/
# directory unmaterialized in runfiles (Bazel only materializes files explicitly declared as
# data/srcs), so every one of these needs listing explicitly for autoparse to find them all.
_CICADA_DICT_HEADERS = [
    "@cicada//:Library/_CROOTData.hh",
    "@cicada//:Library/CClassifierResultsData.hh",
    "@cicada//:Library/CMemberVariables.hh",
    "@cicada//:Library/CMTEWithClassifierResultsData.hh",
    "@cicada//:Library/CProcessedMPTData.hh",
    "@cicada//:Library/CROOTData.hh",
]

# The first thing Cling does for each dictionary at process start is TCling::LoadPCM, which
# checks a single, specific path baked into the compiled dictionary at rootcling generation
# time: wherever that dictionary's _rdict.pcm target lands in bazel-out, in its declaring
# package -- not wherever the consuming binary lives, and not the separate, differently-named
# "local copy" genrules below (those serve a different lookup: Cling checking next to the
# running binary's bazel-out directory, consulted only if this first one fails). Bazel only
# materializes a file if something in the build graph depends on it; without a dependency on
# these dictionaries' original PCM targets, this first lookup always reported "file does not
# exist" (harmless -- Cling falls back further -- but adds debugging noise). Declaring them as
# data forces Bazel to build and place each one at exactly the path this first lookup checks.
_RAW_PCM_TARGETS = [
    "@cicada//:CicadaDict_pcm",
    "//Source/IO:IODict_pcm",
    "//Source/Utility:UtilityDict_pcm",
]

def _root_include_path_wrapper(name, real_bin_label, pcm_data, wrapper_rule, testonly):
    """Shared implementation behind root_include_path_launcher/root_include_path_test_launcher.

    libCore.so is a dependency of every Katydid module .so (katydid_io, katydid_utility,
    etc.); per the ELF spec, a shared object's dependencies' constructors run before its own.
    So libCore.so's constructor always runs before any code of ours and reads/caches
    ROOT_INCLUDE_PATH then. A value set from inside the process, however early, is never
    seen. It must be set externally, before the process starts.

    real_bin_label's path is baked into the script via $(rlocationpath ...) at build time, not
    $(location ...): the former already includes the repository-qualified prefix rlocation
    expects, so the script calls rlocation directly with no extra path work. A rename or move
    of real_bin_label is then a build-time break, not a silent one.

    use_bash_launcher = True initializes the runfiles library; the deps entry on the runfiles
    library is also required - the generated launcher looks for it at a path this deps entry
    provides, but use_bash_launcher does not add the dependency itself.

    wrapper_rule is sh_binary or sh_test: the wrapper execs into real_bin_label without
    forking, so the real binary's exit code (and, for a test, pass/fail) propagates to Bazel
    directly through the wrapper either way.

    testonly must be True whenever real_bin_label is itself testonly (any cc_test): sh_test
    already defaults testonly to True, but the intermediate genrule below isn't a
    "*_test"-named rule, so it gets no such default and needs it set explicitly, or a plain
    `bazel build //...` refuses to analyze it ("non-test target ... depends on testonly
    target ... and doesn't have testonly attribute set").

    Args:
        name: name of the generated sh_binary/sh_test.
        real_bin_label: label of the real binary/test this wraps (e.g. ":Katydid_bin").
        pcm_data: PCM local-copy genrule labels this wraps also needs as data, so Cling finds
            them next to the real, exec'd binary (see BUILD.bazel's comment on those genrules).
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
        # $ meant to stay literal at the script's runtime (not genrule's build time) is
        # doubled ($$), including the final "$@" (arg forwarding): $$@ survives as a literal
        # $@ rather than colliding with genrule's bare $@ output-file token, since Bazel's $$
        # escaping is a single left-to-right pass that takes precedence over interpreting
        # what follows.
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

    # data is needed here so these files are part of this target's runfiles: Cling looks
    # for the headers via ROOT_INCLUDE_PATH (set above) and the PCMs directly alongside the
    # running binary.
    #
    # Original files, not local copies, for _CICADA_DICT_HEADERS: ROOT_INCLUDE_PATH is a
    # general search path, not tied to any one directory, so the originals work as-is.
    wrapper_rule(
        name = name,
        testonly = testonly,
        srcs = [":" + genrule_name],
        data = [
            real_bin_label,
        ] + _CICADA_DICT_HEADERS + _RAW_PCM_TARGETS + pcm_data,
        use_bash_launcher = True,
        deps = ["@rules_shell//shell/runfiles"],
    )

def root_include_path_launcher(name, real_bin_label, pcm_data = _DEFAULT_PCM_DATA):
    """Sets ROOT_INCLUDE_PATH before real_bin_label's process starts, then execs it.

    Args:
        name: name of the generated sh_binary.
        real_bin_label: label of the real binary this wraps (e.g. ":Katydid_bin").
        pcm_data: see _root_include_path_wrapper. Defaults to this package's local copies.
    """
    _root_include_path_wrapper(name, real_bin_label, pcm_data, sh_binary, testonly = False)

def root_include_path_test_launcher(name, real_bin_label, pcm_data):
    """Test counterpart of root_include_path_launcher: wraps a cc_test as a real sh_test.

    Intended to wrap every Validation cc_test unconditionally, not just ones already known to
    touch Cicada's ROOT dictionary at runtime: harmless for a test that doesn't need it, and
    removes the need to reason case-by-case about which ones do (see
    Source/Executables/Validation/BUILD.bazel's top comment).

    Args:
        name: name of the generated sh_test.
        real_bin_label: label of the real cc_test this wraps (e.g. ":TestVector_bin").
        pcm_data: see _root_include_path_wrapper. No default: these are package-relative
            labels defined in the calling package (e.g. Validation's local PCM copies), not
            this one.
    """
    _root_include_path_wrapper(name, real_bin_label, pcm_data, sh_test, testonly = True)
