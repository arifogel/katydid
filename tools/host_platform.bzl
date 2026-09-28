"""Extends Bazel's auto-detected host platform with a Linux-distro constraint (AlmaLinux vs.
everything else), exposed as @host_platform, so select() can branch on it with no --config or
--define flag ever passed at the command line.

@platforms only models OS/CPU, not Linux distro, so there's no existing constraint_value a
select() can match on to tell AlmaLinux apart from Ubuntu. This repository rule detects it the
same way tools/root.bzl already auto-detects platform - via linux_distro_id, a
repository-rule-time host check - and writes out a platform() that inherits everything else
(os, cpu, ...) from Bazel's own default autodetected host platform (@local_config_platform//:
host, Bazel's built-in --platforms default) via `parent`, adding only the one new constraint
value this file cares about.

.bazelrc points --platforms at this platform unconditionally (see its comment), so every
build/test invocation resolves it automatically - the same way choosing between an
@platforms//os:linux and @platforms//os:macos select() branch already requires no flag today.
Nothing here changes os/cpu/toolchain resolution for anything that doesn't ask about Linux
distro specifically.

Usage from a BUILD file: select({"//tools:is_almalinux": [...], "//conditions:default": [...]})
"""

load(":repo_utils.bzl", "linux_distro_id")

def _host_platform_repo_impl(repository_ctx):
    on_almalinux = linux_distro_id(repository_ctx) == "almalinux"

    repository_ctx.file("BUILD.bazel", """
constraint_setting(name = "linux_distro")

constraint_value(
    name = "almalinux",
    constraint_setting = ":linux_distro",
)

platform(
    name = "auto",
    parent = "@local_config_platform//:host",
    constraint_values = {constraint_values},
)
""".format(constraint_values = repr([":almalinux"] if on_almalinux else [])))

_host_platform_repo = repository_rule(
    implementation = _host_platform_repo_impl,
    local = True,  # re-evaluate every build so switching machines/containers is picked up
)

def _host_platform_impl(_module_ctx):
    _host_platform_repo(name = "host_platform")

host_platform = module_extension(implementation = _host_platform_impl)
