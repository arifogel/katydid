# Bazel build: architecture and maintenance notes

This document is for people maintaining or extending Katydid's Bazel build. For a plain guide
to building and running Katydid, see [BUILDING.md](BUILDING.md) instead.

It assumes familiarity with Bazel concepts (repository rules, module extensions, `cc_library`)
and with C/C++ build and link mechanics generally.

## Design goals

1. **A single command (`bazel build //...`) builds Katydid from a clean checkout**, without
   requiring `git submodule update`, a CMake configure step, or manually building any of
   Katydid's own bundled dependencies (Nymph, Scarab, Cicada).
2. **Large scientific libraries that are already the user's responsibility on any platform**
   (ROOT, Boost, FFTW, MatIO) are treated as system-provided, not built by Bazel. This is a
   deliberate trade against full hermeticity: it avoids the very large time cost of building
   ROOT from source inside Bazel, at the cost of exact reproducibility across machines.
3. Supports macOS, Ubuntu 24.04, and AlmaLinux 9, with the platform-specific logic isolated to
   as few places as possible.

## Repository layout

- `MODULE.bazel` — the Bazel module definition. Declares two module extensions:
  `tools/non_bazel_deps.bzl` (fetches Katydid's own git-based dependencies) and
  `tools/system_deps.bzl` (locates system-provided libraries).
- `tools/non_bazel_deps.bzl` — fetches Nymph, Scarab, Cicada, rapidjson, and yaml-cpp as pinned
  git commits, each paired with a hand-written `BUILD.bazel` file under `third_party/`, since
  none of them have native Bazel support upstream.
- `tools/system_deps.bzl` — locates ROOT, Boost, FFTW, and MatIO on the host machine and exposes
  them as `cc_library` targets under the repository name `@homebrew` (see below for why that
  name is retained on Linux too).
- `tools/root_dictionary.bzl` — a Bazel rule wrapping `rootcling`, replacing CMake's
  `ROOT_GENERATE_DICTIONARY()` macro.
- `Source/*/BUILD.bazel` — one per active Katydid module, translated from the corresponding
  `CMakeLists.txt`.
- `third_party/*/BUILD.*.bazel` — hand-written build files for Nymph, Scarab, Cicada, rapidjson,
  and yaml-cpp, none of which build with Bazel natively.
- `vendor/*/BUILD.bazel` — build files for the small libraries already vendored directly into
  the Katydid tree (`nanoflann`, `RapidXML`).

## How ROOT, Boost, FFTW, and MatIO are located

`tools/system_deps.bzl` implements a single repository rule, exposed as `@homebrew`, that
branches on the host platform:

- **ROOT** is located identically on every platform: by requiring `root-config` to already be
  on `PATH`. This works whether ROOT came from Homebrew, a manually-extracted binary tarball, or
  any other installation method, since `root-config` is ROOT's own official query tool and every
  ROOT distribution ships one. The rule queries `root-config --incdir`, `--libdir`, and
  `--libs`, and adds `-lGui -lSpectrum -lTMVA` on top of the base libraries, matching Katydid's
  `find_package(ROOT 6.00 COMPONENTS Gui Spectrum TMVA)` in the original CMake build. `rootcling`
  is located via `root-config --bindir` and exposed as `@homebrew//:rootcling`.
- **Boost, FFTW, and MatIO** are located differently depending on the package manager:
  - On **macOS**, via Homebrew (`brew --prefix <formula>`), since Homebrew deliberately installs
    outside the compiler's default search paths.
  - On **Linux**, via whichever of `apt-get` or `dnf` is found on `PATH` — not by checking the
    OS release name, so this doesn't need updating for other Linux distributions using the same
    package managers. Neither `apt` nor `dnf` need explicit include/library paths, since both
    install into the compiler and linker's default search locations.
  - Correctness is checked by looking for a representative header file for each library
    (`boost/version.hpp`, `fftw3.h`, `matio.h`), not by asking the package manager whether a
    specific package name is installed. This matters in practice: some Linux package managers
    use "transitional" wrapper packages for versioned libraries (e.g. Ubuntu's
    `libboost-filesystem-dev` simply depends on the real `libboost-filesystem1.83-dev`), and
    certain caching mechanisms used in CI do not reliably register these wrapper packages even
    though the underlying files are present and working. Checking for the actual header
    sidesteps this entirely.
- The repository name `@homebrew` is retained even though it also covers `apt`/`dnf` now,
  to avoid touching every `BUILD.bazel` file that references it for a purely cosmetic rename.

`FFTW_FOUND` and `ROOT_FOUND` — preprocessor defines Katydid's own source checks with `#ifdef`
— are set as `defines` directly on the `@homebrew//:fftw` and `@homebrew//:root` targets, so
they propagate automatically to every target that depends on them, matching what
`add_definitions(-DFFTW_FOUND)` did project-wide in the CMake build.

`boost_system` is deliberately not linked: `Boost.System` has been header-only since Boost
1.69, and Boost 1.89 removed the compiled stub library outright, so linking it fails on any
current Boost installation.

## ROOT dictionary generation (`tools/root_dictionary.bzl`)

Three Katydid modules (`Utility`, `IO`) and Cicada generate a ROOT dictionary from a
`LinkDef.hh` file, replacing CMake's `ROOT_GENERATE_DICTIONARY()`. This needs to be a real
Starlark rule rather than a plain `genrule`, because `rootcling` must see every header
transitively reachable from the dictionary headers (via Nymph, Scarab, Boost, and so on), and
only a rule that reads the `CcInfo` provider of its `deps` can obtain the actual transitive
include paths Bazel already knows about.

Each module using this exposes a headers-only `cc_library` (e.g. `katydid_utility_headers`)
purely so the dictionary rule has something to depend on for compilation-context purposes,
without creating a circular dependency (the real library's `srcs` include the generated
dictionary `.cxx`, so it cannot itself be the dictionary rule's dependency).

`rootcling` is invoked with header **basenames**, not full paths: with `-inlineInputHeader`,
whatever string is passed on the command line is embedded literally as the `#include` target
in the generated `.cxx`. A full path resolvable at generation time is not necessarily
resolvable later when that file is actually compiled from a different location under Bazel's
output tree; basenames combined with the correct `-I` flags resolve correctly in both places.

The generated `.pcm` file is wired in as `data` (a runtime dependency), not just a build input:
ROOT's class loader looks for it next to the compiled library or executable at runtime, not
just at compile time.

## Known pre-existing issues in Katydid's source

Two bugs were found in the process of porting Source/Utility's build, independent of Bazel —
worth fixing upstream, not routed around by this build:

- `Source/Utility/KTSpline.hh` declares `Implement()` returning
  `std::shared_ptr<Implementation>`, but `KTSpline.cc` still defines the old signature,
  returning a raw `KTPhysicalArray<1,double>*`. `KTSpline.cc` is excluded from the build until
  this is fixed.
- `Source/Utility/KTKatydidApp.hh` defines `GetTApplication()` out-of-class in the header
  without the `inline` keyword — a One Definition Rule violation that only manifests when
  statically linking (as Bazel's default `cc_library` does), not when linking against a shared
  library (as the original CMake build, with `BUILD_SHARED_LIBS ON`, does). This has been fixed
  directly in the header by adding `inline`.

`Source/Simulation` and `Source/Evaluation` are not part of the Bazel build. Both are already
excluded from the CMake build itself (`add_subdirectory` for both is commented out in the
top-level `CMakeLists.txt`), and independently have real content issues:
`Simulation/KTTSGenerator.cc` includes a `thorax.hh` that does not exist anywhere in the
repository, and `Evaluation/KTCompareCandidates` depends on classes that are themselves
excluded from `Data/CMakeLists.txt`'s own source list. `Source/Time` is excluded from the
Bazel build for the same reason (also commented out of the CMake build), and is not needed by
anything that is built — `SpectrumAnalysis` depends only on `IO` and `Transform`, despite
`Time` being a sibling directory.

Monarch (`Source/Time/Monarch`) is not built: `Katydid_USE_MONARCH` defaults off, and nothing
outside its own `#ifdef` guard touches it.

## CI (`.github/workflows/ci.yaml`)

Three platforms are tested: `ubuntu-24.04` and `macos-14` as a matrix within one job, and
AlmaLinux 9 as a fully separate job running inside the official `almalinux:9` container image
(GitHub does not offer AlmaLinux as a native runner OS). The AlmaLinux job is kept separate
rather than added as a third matrix value specifically to avoid a known GitHub Actions issue
([actions/runner#265](https://github.com/actions/runner/issues/265)) where an empty-string
`container:` value used to mean "no container" on some matrix legs can fail workflow
validation outright.

Because `bazel-contrib/setup-bazel`'s automatic Bazel installation does not reliably produce a
working `bazel` binary inside the minimal `almalinux:9` image, that job installs
[Bazelisk](https://github.com/bazelbuild/bazelisk) directly instead, before calling
`setup-bazel` (still used afterward for its build/repository caching).

ROOT's prebuilt binaries for both Ubuntu and AlmaLinux dynamically depend on shared libraries
that are not present by default on a fresh container or runner image (`libtbb`, `libxxhash`)
— the AlmaLinux job includes a step that runs `ldd` against `rootcling` immediately after
extracting it, so that any other missing shared library is caught in one clear failure rather
than discovered one Bazel build at a time.

`.github/workflows/lockfile-sync.yaml` keeps `MODULE.bazel.lock` up to date on pull requests
opened by Renovate. It needs the same system-library provisioning as the main CI job's Ubuntu
path, because `bazel mod deps` evaluates every module extension declared in `MODULE.bazel` —
including `tools/system_deps.bzl` — to compute the lockfile, and that extension hard-fails
without Boost/FFTW/MatIO/ROOT actually present.

## Known limitations / possible future work

- ROOT, Boost, FFTW, and MatIO are not built hermetically; the exact versions used depend on
  what is installed on the host. `MODULE.bazel.lock` only pins the Bazel Central Registry
  dependencies (`rules_cc`, `platforms`).
- A shared HPC cluster deployment (no root/administrator access for ordinary users) has not
  been built out. The likely approach: a minimal `dnf install` request to a cluster
  administrator for the four `-devel` packages `tools/system_deps.bzl` already needs, plus a
  user-writable ROOT tarball installation (not `/opt`, which ordinary users typically cannot
  write to). Worth checking first whether the cluster already provides these via CVMFS or an
  environment module system, which could reduce or eliminate the administrator request
  entirely.
- Boost, FFTW, and MatIO could in principle be built hermetically by Bazel instead of relying
  on the system package manager — `rules_boost` (which pairs Boost's source with hand-written
  native `cc_library` build files, avoiding Boost's own `b2` build system) is the natural
  starting point for Boost specifically. ROOT is a much larger undertaking and not recommended:
  a full source build is slow, and there is no maintained "ROOT for Bazel" project to build on.
