"""Generates an sh_binary that sets ROOT_INCLUDE_PATH before the real binary it wraps starts."""

load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

# Copied into the genrule's own runfiles/data below, so Cling finds them directly alongside
# the running binary. See BUILD.bazel's comment above the producing genrules.
_PCM_DATA = [
    ":CicadaDict_pcm_local_copy",
    ":IODict_pcm_local_copy",
]

def root_include_path_launcher(name, real_bin_label):
    """Sets ROOT_INCLUDE_PATH before real_bin_label's own process starts, then execs it.

    libCore.so is a dependency of libroot_dict_shared.so; per the ELF spec, a shared
    object's dependencies' constructors run before its own. So libCore.so's constructor
    always runs before any code of ours and reads/caches ROOT_INCLUDE_PATH then. A value set
    from inside the process, however early, is never seen. It must be set externally, before
    the process starts.

    real_bin_label's path is baked into the generated script via Bazel's $(rlocationpath ...)
    expansion at build time: a rename or move of real_bin_label is a build-time break, not a
    silent one. $(rlocationpath ...), not $(location ...): the former already includes the
    repository-qualified prefix rlocation expects, so the script calls rlocation on it
    directly with no extra path work.

    use_bash_launcher = True initializes the runfiles library. deps on the runfiles library
    itself is also required: use_bash_launcher's generated launcher looks for the library at
    a path this deps entry provides, but does not add the dependency itself.

    Args:
        name: name of the generated sh_binary.
        real_bin_label: label of the real binary this wraps (e.g. ":Katydid_bin").
    """
    genrule_name = name + "_launcher_gen"
    native.genrule(
        name = genrule_name,
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

    # _PCM_DATA is needed here so these files are part of this target's own runfiles: Cling
    # looks for them directly alongside the running binary.
    #
    # @cicada//:Library/_CROOTData.hh, not a local copy: ROOT_INCLUDE_PATH (set above) is a
    # general search path, not tied to any directory, so the original file works.
    sh_binary(
        name = name,
        srcs = [":" + genrule_name],
        data = [
            real_bin_label,
            "@cicada//:Library/_CROOTData.hh",
        ] + _PCM_DATA,
        use_bash_launcher = True,
        deps = ["@rules_shell//shell/runfiles"],
    )
