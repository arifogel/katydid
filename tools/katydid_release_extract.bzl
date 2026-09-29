"""katydid_release_extract(): extracts //:katydid_release's own tarball into a tree artifact at
ordinary build time.

Repository rules can only resolve source files or another repo's own already-fetched content,
never another target's build output in the same build, so consuming //:katydid_release's pkg_tar
output as a dependency requires an ordinary action rather than a repository rule.
"""

def _katydid_release_extract_impl(ctx):
    extracted = ctx.actions.declare_directory(ctx.label.name)
    ctx.actions.run_shell(
        inputs = [ctx.file.release_tar],
        outputs = [extracted],
        command = "tar xzf '{tar}' -C '{out}'".format(tar = ctx.file.release_tar.path, out = extracted.path),
        mnemonic = "ExtractKatydidRelease",
        progress_message = "Extracting %s" % ctx.file.release_tar.short_path,
    )
    return [DefaultInfo(
        files = depset([extracted]),
        runfiles = ctx.runfiles(files = [extracted]),
    )]

katydid_release_extract = rule(
    implementation = _katydid_release_extract_impl,
    attrs = {
        "release_tar": attr.label(
            default = Label("//:katydid_release"),
            allow_single_file = True,
            doc = "The //:katydid_release tarball to extract.",
        ),
    },
)
