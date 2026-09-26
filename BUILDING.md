# Building Katydid with Bazel

This page explains how to build and run Katydid using [Bazel](https://bazel.build), as an
alternative to the CMake/Docker workflow described in the main [README](README.md). You do not
need any programming background beyond what you'd already use to build Katydid the old way —
just follow the steps for your operating system below.

## What is Bazel, and why would I use it?

Bazel is a build tool, like CMake, but with one property that matters for Katydid: once you've
installed a short list of system libraries (below), Bazel downloads and builds everything else
automatically — Nymph, Scarab, Cicada, and Katydid's other bundled dependencies — with a single
command. There's no `git submodule update`, no `ccmake` configuration screen, and no separate
install step. If you edit a source file and rebuild, Bazel recompiles only what changed.

This is currently a secondary way to build Katydid, alongside the CMake/Docker workflow. Use
whichever one your collaborators or supervisor recommend if you're not sure.

## Supported platforms

| Platform | Status |
|---|---|
| macOS (Apple Silicon) | Regularly used and tested |
| Ubuntu 24.04 (x86_64) | Regularly used and tested |
| AlmaLinux 9 (x86_64) | Verified to build in automated testing; step-by-step instructions for a shared cluster (no administrator access) are not written yet — ask a maintainer if you need this |

If you're on a different OS or Linux distribution, most of these instructions should still be
close to correct, but you may need help from someone familiar with Bazel.

## 1. Install Bazel

Bazel is normally installed via a small helper program called **Bazelisk**, which reads a file
in the Katydid repository (`.bazelversion`) and automatically downloads the exact version of
Bazel that Katydid needs. You don't need to think about Bazel version numbers yourself.

**macOS:**
```
brew install bazelisk
```

**Ubuntu 24.04:**
```
sudo wget -O /usr/local/bin/bazel https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-amd64
sudo chmod +x /usr/local/bin/bazel
```

Either way, once this is done, typing `bazel` at a terminal will transparently do the right
thing.

## 2. Install the system libraries Katydid needs

Bazel fetches Katydid's own bundled dependencies (Nymph, Scarab, Cicada, and a few small
libraries) automatically, and - on the three platforms above - ROOT too, as a prebuilt binary
downloaded directly by Bazel the first time you build. There's nothing to install for ROOT
specifically: no `brew install root`, no manual download, no `PATH`/`thisroot.sh` setup.

Boost, FFTW, and MatIO are still installed the normal way for your operating system.

### macOS

```
brew install boost fftw libmatio
```

That's it — nothing else to configure. Bazel will find these automatically.

### Ubuntu 24.04

Run the setup script included in the repository:
```
./install-ubuntu-24.04-build-deps.sh
```

This installs Boost, FFTW, and MatIO through `apt`, in a way that can be cleanly removed later
(via `sudo apt remove katydid-build-deps && sudo apt autoremove`) if you ever need to.

## 3. Build Katydid

From the root of the repository:
```
bazel build //Source/Executables/Main:Katydid
```

The first build will take a while — Bazel is downloading Nymph, Scarab, Cicada, and a few other
dependencies, and compiling everything from scratch. After that, rebuilds are fast, and only
recompile what you've actually changed.

## 4. Run Katydid

```
bazel run //Source/Executables/Main:Katydid -- -c my_config_file.json
```

(The `--` separates Bazel's own arguments from the ones you're passing to Katydid itself — this
is the Bazel equivalent of just typing `Katydid -c my_config_file.json` after a CMake build.)

The `Truncate` utility is available the same way:
```
bazel run //Source/Executables/Main:Truncate -- [arguments]
```

## Using CLion

CLion has a Bazel plugin (search for "Bazel" in CLion's plugin marketplace) that understands
this repository directly — once installed, you can open the repository as a Bazel project, and
CLion will offer `Katydid` and `Truncate` as ordinary run/debug configurations, with full
debugging support (breakpoints, stepping, variable inspection) through `lldb`.

## If something goes wrong

- **"No prebuilt ROOT binary is configured for ... in tools/root.bzl"** — you're on a
  platform this repository doesn't have a baked-in ROOT download for yet (see the "Supported
  platforms" table above). Ask a maintainer, or see `tools/root.bzl`'s `_ROOT_DOWNLOADS`
  table for how to add one.
- **`brew` was not found on PATH** (macOS) — install [Homebrew](https://brew.sh) first.
- **Missing header errors mentioning Boost, FFTW, or MatIO** — the setup script or `brew
  install` step above wasn't run, or didn't complete successfully. Re-run it and check for
  errors.
- **Anything else** — please reach out to a maintainer rather than trying to debug Bazel
  internals yourself; see `NOTES.md` if you're comfortable with build-system troubleshooting,
  or ask in whatever channel your group uses for Katydid support.
