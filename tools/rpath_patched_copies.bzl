"""rpath_patched_copies copies each src into <name>/ with its RPATH replaced (Linux, patchelf)."""

def _rpath_patched_copies_impl(ctx):
    outputs = []
    for src in ctx.files.srcs:
        out = ctx.actions.declare_file(ctx.label.name + "/" + src.basename)
        ctx.actions.run_shell(
            outputs = [out],
            inputs = [src],
            tools = [ctx.executable._patchelf],
            command = "cp -f '{src}' '{out}' && chmod +w '{out}' && '{patchelf}' --set-rpath '{rpath}' '{out}'".format(
                src = src.path,
                out = out.path,
                patchelf = ctx.executable._patchelf.path,
                rpath = ctx.attr.rpath,
            ),
            mnemonic = "RpathPatchedCopy",
            progress_message = "Patching RPATH of %s" % src.basename,
        )
        outputs.append(out)
    return [DefaultInfo(files = depset(outputs))]

rpath_patched_copies = rule(
    implementation = _rpath_patched_copies_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True, doc = "Files to copy. May be empty."),
        "rpath": attr.string(mandatory = True, doc = "RPATH to set, verbatim."),
        "_patchelf": attr.label(default = Label("@patchelf//:patchelf"), executable = True, cfg = "exec"),
    },
    doc = "Copies srcs with their RPATH replaced.",
)
