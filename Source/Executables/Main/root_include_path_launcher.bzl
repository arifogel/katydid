"""Generates an sh_binary that sets ROOT_INCLUDE_PATH before the real binary it wraps starts."""

load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

# Copied into a genrule's own runfiles/data below, so Cling finds them sitting directly
# alongside whatever binary is actually running -- see BUILD.bazel's own, fuller comment
# right above the genrules that produce these, for why.
_PCM_DATA = [
    ":CicadaDict_pcm_local_copy",
    ":CicadaDict_header_local_copy",
    ":IODict_pcm_local_copy",
]

def root_include_path_launcher(name, real_bin_label):
    """Sets ROOT_INCLUDE_PATH before real_bin_label's own process starts, then execs it.

    This has to happen externally, from a wrapper, rather than from any code running inside
    the process: libCore.so is itself a dependency of libroot_dict_shared.so, and per the ELF
    spec's own ordering guarantee, a shared object's dependencies' constructors always run
    before its own -- so libCore.so's own constructor always runs before any code of ours,
    regardless of constructor priority, and it reads and caches ROOT_INCLUDE_PATH that early.
    ROOT/Cling's autoload machinery never sees a value set later, from inside the process, no
    matter how early.

    real_bin_label's own path is baked directly into the generated script's own content, via
    a genrule using Bazel's own $(rlocationpath ...) expansion at build time -- not a
    checked-in script with the path hardcoded by hand: a rename or move of real_bin_label is
    a build-time break here, not a silent, unnoticed one. $(rlocationpath ...), not
    $(location ...): the former already includes the repository-qualified prefix rlocation
    itself expects (e.g. "_main/Source/Executables/Main/Katydid_bin"), so the generated
    script can call rlocation on it directly, with no separate runfiles_current_repository
    call or manual path concatenation needed -- Bazel's own docs describe this as the
    preferred way to find a data dependency's own runtime path in the first place, not just a
    shortcut. Not passed via this sh_binary's own args attribute either (an earlier attempt):
    confirmed directly, args never gets baked into the underlying file at all, only applied
    by Bazel's own bazel run/test invocation machinery, so it's absent whenever the file is
    invoked directly as a subprocess, which is exactly how this is actually used (the
    packaged release archive, katydid_stderr_test).

    use_bash_launcher = True initializes the runfiles library automatically, rather than this
    generated script copying in the library's own init snippet by hand (an earlier attempt):
    that hand-copied version was itself only needed because use_bash_launcher's own generated
    launcher execs the underlying script via its resolved runfiles path, resetting $0 --
    which broke a still-earlier design that inferred the real binary from $0. Nothing here
    reads $0 for anything anymore, so that concern no longer applies, and Bazel's own
    initialization can be used directly. deps on the runfiles library is still needed
    alongside it: confirmed directly, use_bash_launcher's own generated launcher looks for
    the library but doesn't add the dependency that makes it available -- without deps, this
    fails outright with "ERROR: cannot find bazel_tools/tools/bash/runfiles/runfiles.bash".

    Args:
        name: name of the generated sh_binary.
        real_bin_label: label of the real binary this wraps (e.g. ":Katydid_bin").
    """
    genrule_name = name + "_launcher_gen"
    native.genrule(
        name = genrule_name,
        srcs = [
            real_bin_label,
            ":CicadaDict_header_local_copy",
        ],
        outs = [name + "_launcher_gen.sh"],
        # Every $ meant to stay literal (for this script's own logic to interpret at its own
        # runtime, not Bazel at genrule build time) is doubled ($$) below, per Bazel's own
        # genrule cmd escaping rules -- including the final "$@" (this script's own
        # argument-forwarding), which needs to survive as a literal, doubled $$@ without
        # colliding with genrule's own, unrelated bare $@ token for its single output file.
        # Checked directly against Bazel's own documented genrule cmd expansion behavior (a
        # single, left-to-right pass: $$ escaping takes precedence over interpreting what
        # follows as a separate Make variable), not assumed.
        cmd = """cat > $@ << 'LAUNCHER_EOF'
#!/usr/bin/env bash
REAL_BIN="$$(rlocation "$(rlocationpath %s)")"
CROOT_DATA_HH="$$(rlocation "$(rlocationpath :CicadaDict_header_local_copy)")"
CROOT_DATA_DIR="$$(dirname "$${CROOT_DATA_HH}")"

# Appends to, rather than replaces, any pre-existing ROOT_INCLUDE_PATH (e.g. one set
# manually for interactive/debug use), so both take effect.
if [[ -n "$${ROOT_INCLUDE_PATH:-}" ]]; then
  export ROOT_INCLUDE_PATH="$${ROOT_INCLUDE_PATH}:$${CROOT_DATA_DIR}"
else
  export ROOT_INCLUDE_PATH="$${CROOT_DATA_DIR}"
fi

exec "$${REAL_BIN}" "$$@"
LAUNCHER_EOF
chmod +x $@
""" % real_bin_label,
    )

    # _PCM_DATA is needed here too, so these files are part of this target's own runfiles at
    # all: ROOT's Cling interpreter looks for them sitting directly alongside whatever binary
    # is actually running -- see _PCM_DATA's own comment above.
    sh_binary(
        name = name,
        srcs = [":" + genrule_name],
        data = [real_bin_label] + _PCM_DATA,
        use_bash_launcher = True,
        deps = ["@rules_shell//shell/runfiles"],
    )
