"""Shared repository_ctx helpers for tools/root.bzl and its sibling library-fetch files."""

def is_macos(repository_ctx):
    return repository_ctx.os.name.lower().startswith("mac")

def linux_distro_id(repository_ctx):
    """Reads /etc/os-release's ID field (e.g. "ubuntu", "almalinux").

    Args:
        repository_ctx: the repository_rule's repository_ctx.

    Returns:
        The ID field's value, or None if not found.
    """
    os_release = repository_ctx.read("/etc/os-release")
    for line in os_release.splitlines():
        if line.startswith("ID="):
            return line[len("ID="):].strip('"')
    return None
