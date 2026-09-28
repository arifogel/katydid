# Bazel build: architecture and maintenance notes

This document is for people maintaining or extending Katydid's Bazel build. For a plain guide
to building and running Katydid, see [BUILDING.md](BUILDING.md) instead.

It assumes familiarity with Bazel concepts (repository rules, module extensions, `cc_library`)
and with C/C++ build and link mechanics generally.

## Design goals

1. **A single command (`bazel build //...`) builds Katydid from a clean checkout**, without
   requiring `git submodule update`, a CMake configure step, or manually building any of
   Katydid's own bundled dependencies (Nymph, Scarab, Cicada).
2. **Boost, FFTW, and MatIO** are located differently per platform. On macOS and Ubuntu they are
   treated as system-provided (Homebrew/apt), a deliberate trade against full hermeticity, at the
   cost of exact reproducibility across machines. On AlmaLinux they are instead fetched
   hermetically by Bazel itself, from pinned, permalinked package archives - AlmaLinux's rolling
   `dnf` mirror prunes superseded package builds outright, so `dnf install` there is not
   reproducible the way `apt`/Homebrew effectively are in practice. ROOT is always fetched by
   Bazel itself, as a pinned, exact prebuilt binary per platform, since there's no existing
   hermetic Bazel toolchain to build it from source.
3. Supports macOS, Ubuntu 24.04, and AlmaLinux 9, with the platform-specific logic isolated to
   as few places as possible: one retrieval file per platform (`tools/macos_libs.bzl`,
   `tools/ubuntu_libs.bzl`, `tools/almalinux_libs.bzl`), resolved to a single label surface
   (`tools/binary_deps.bzl`) that the rest of the build depends on, with no build flags anywhere
   (no `--define`, `--config`, or `--platforms`) - see the section below.

## Repository layout

- `MODULE.bazel` — the Bazel module definition. Declares the module extensions:
  `tools/non_bazel_deps.bzl` (fetches Katydid's own git-based dependencies),
  `tools/root.bzl` (fetches ROOT), and the Boost/FFTW/MatIO retrieval-and-resolution extensions
  below (`tools/macos_libs.bzl`, `tools/ubuntu_libs.bzl`, `tools/almalinux_libs.bzl`,
  `tools/binary_deps.bzl`).
- `tools/non_bazel_deps.bzl` — fetches Nymph, Scarab, Cicada, rapidjson, and yaml-cpp as pinned
  git commits, each paired with a hand-written `BUILD.bazel` file under `third_party/`, since
  none of them have native Bazel support upstream. Also applies two source patches to Scarab
  (see "Known pre-existing issues" below).
- `tools/root.bzl` — fetches a prebuilt ROOT binary from root.cern for the current platform,
  exposed as `@root`.
- `tools/repo_utils.bzl` — `repository_ctx` helpers (`is_macos`, `linux_distro_id`) shared
  between `tools/root.bzl` and the Boost/FFTW/MatIO retrieval files below.
- `tools/brew.bzl` — plain Homebrew helper functions (not a repository rule/module extension of
  its own), used by both `tools/macos_libs.bzl` and `tools/binary_deps.bzl`.
- `tools/macos_libs.bzl` — locates Boost, FFTW, and MatIO via Homebrew, exposed as
  `@macos_libs`.
- `tools/ubuntu_libs.bzl` — locates Boost, FFTW, and MatIO via `apt`'s default search paths,
  exposed as `@ubuntu_libs`.
- `tools/almalinux_libs.bzl` — fetches Boost, FFTW, MatIO, and the extra libraries ROOT's own
  prebuilt AlmaLinux binaries need (TBB, xxhash, FreeType, GSL) hermetically, from pinned
  package archives, exposed as `@almalinux_libs`.
- `tools/binary_deps.bzl` — resolves Boost/FFTW/MatIO (and, on AlmaLinux, the ROOT-runtime
  extras) to whichever of the three repos above actually applies on the current host, exposed
  as `@binary_deps` — the one label surface the rest of the build depends on. See "How ROOT,
  Boost, FFTW, and MatIO are located" below for how the resolution works.
- `tools/root_dictionary.bzl` — a Bazel rule wrapping `rootcling`, replacing CMake's
  `ROOT_GENERATE_DICTIONARY()` macro.
- `Source/*/BUILD.bazel` — one per active Katydid module, translated from the corresponding
  `CMakeLists.txt`.
- `Source/Executables/Main/BUILD.bazel` — builds the `Katydid` and `Truncate` command-line
  programs.
- `Source/Executables/Validation/BUILD.bazel` — the full validation test suite; see its own
  section below.
- `third_party/*/BUILD.*.bazel` — hand-written build files for Nymph, Scarab, Cicada, rapidjson,
  and yaml-cpp, none of which build with Bazel natively.
- `vendor/*/BUILD.bazel` — build files for the small libraries already vendored directly into
  the Katydid tree (`nanoflann`, `RapidXML`).

Each Katydid/Nymph/Scarab/Cicada/yaml-cpp module is built as its own real, standalone
`cc_shared_library` (e.g. `libKatydidData.so`), keeping the same name and one-library-per-module
structure the original CMake build produces with `BUILD_SHARED_LIBS ON` - so existing consumers'
linking assumptions carry over unchanged.

## How ROOT, Boost, FFTW, and MatIO are located

**ROOT** (`tools/root.bzl`) is fetched directly as a prebuilt binary from root.cern, one exact,
baked-in URL per supported platform (Ubuntu 24.04, AlmaLinux 9.x, macOS on arm64), pinned to one
`_ROOT_VERSION`, exposed as `@root`. ROOT's prebuilt binaries are versioned per exact OS release
and toolchain, not just "linux" or "macos", so this reads `/etc/os-release`'s `ID` field on
Linux rather than just checking which package manager is on `PATH`. After extracting the
tarball, the rule still queries the now-locally-extracted `root-config --libs` (rather than
hardcoding the libs list), and adds `-lGui -lSpectrum -lTMVA` on top, matching Katydid's
`find_package(ROOT 6.00 COMPONENTS Gui Spectrum TMVA)` in the original CMake build. `rootcling`
is symlinked to the repository root and exposed as `@root//:rootcling`. No installation step,
and no `root-config` needs to already be on `PATH` beforehand.

**Boost, FFTW, and MatIO** are located differently per platform, but every consumer in the
build depends on a single resolved label surface, `@binary_deps` (e.g.
`deps = ["@binary_deps//:boost", "@binary_deps//:fftw"]`) - nothing outside
`tools/binary_deps.bzl` itself references `@macos_libs`, `@ubuntu_libs`, or `@almalinux_libs`
directly. This is a three-layer design:

1. **Retrieval** (one file per platform, each exposing its own repository):
   - `tools/macos_libs.bzl` → `@macos_libs`, via Homebrew (`brew --prefix <formula>`), since
     Homebrew deliberately installs outside the compiler's default search paths. Uses
     `tools/brew.bzl`'s plain helper functions, not a repository rule of its own, so loading
     them doesn't force `@macos_libs` to be fetched on other platforms.
   - `tools/ubuntu_libs.bzl` → `@ubuntu_libs`, via `apt`'s default search paths (no explicit
     include/library paths needed).
   - `tools/almalinux_libs.bzl` → `@almalinux_libs`, fetched hermetically: each package is
     downloaded from a pinned, permalinked URL (`vault.almalinux.org` for AlmaLinux's own
     packages, `dl.fedoraproject.org/pub/archive/epel/` for MatIO, which is an EPEL package) and
     checked against a pinned `sha256`, then extracted with `rpm2cpio`/`cpio` (Bazel's
     `download_and_extract` has no native `.rpm` support). This is the one platform where the
     live package mirror is not usable as a reproducible source - AlmaLinux's rolling `dnf`
     mirror prunes superseded builds outright, unlike `apt`'s or Homebrew's. `tools/pin_rpm.sh`
     computes the `sha256`/prints the dict entry for a new pinned package. Also fetches the four
     extra libraries (TBB, xxhash, FreeType, GSL) ROOT's own prebuilt AlmaLinux binaries dynamically
     depend on but don't bundle, exposed as `@almalinux_libs//:root_runtime_extra_libs`.
   - On macOS and Ubuntu, correctness is checked by looking for a representative header file for
     each library (`boost/version.hpp`, `fftw3.h`, `matio.h`), not by asking the package manager
     whether a specific package name is installed - some Linux package managers use
     "transitional" wrapper packages for versioned libraries (e.g. Ubuntu's
     `libboost-filesystem-dev` simply depends on the real `libboost-filesystem1.83-dev`), and
     certain CI caching mechanisms do not reliably register these wrapper packages even though
     the underlying files are present and working.
2. **Resolution** (`tools/binary_deps.bzl` → `@binary_deps`): picks which of the three retrieval
   repos' labels to alias, entirely inside its own repository rule via `is_macos`/
   `linux_distro_id` - the same host-detection pattern `tools/root.bzl` already uses to pick
   ROOT's per-platform URL. There is no `select()`, `config_setting`, or command-line/`.bazelrc`
   flag anywhere in this resolution: the generated `BUILD.bazel` only ever names the one
   matching platform repo's labels, so the other two are never referenced and so never fetched
   on a given host (the same Bzlmod laziness `tools/root.bzl`'s own single-URL choice already
   relies on). `@binary_deps//:root_runtime_extra_libs` is a real, always-present target (an
   `alias()` to `@almalinux_libs`'s version on AlmaLinux, an empty `filegroup` elsewhere), so
   root `BUILD.bazel` can reference it unconditionally with no `select()` of its own.
   `@binary_deps//:lib_dirs.bzl`'s `LIB_DIRS` (macOS Homebrew formula directories, needed for
   RPATH patching in the release archive) is computed the same way, from `tools/brew.bzl`'s
   `MAC_BREW_FORMULAE` table - the same table `tools/macos_libs.bzl` builds its `cc_import`s
   from.
3. **RPATH modification** at release-packaging time (`Source/Executables/Main/harvest_runtime_libs.bzl`,
   `release_binary.bzl`) - unchanged by which retrieval repo actually backed `@binary_deps` on a
   given host.

Everything under `@almalinux_libs` is bundled into the release archive uniformly (harvested like
any other real Bazel dependency, or listed directly via `root_runtime_extra_libs`), since it's
all fetched the same hermetic way there. On macOS and Ubuntu, Boost/FFTW/MatIO are excluded from
the harvest and never bundled - the release archive relies on them already being present on the
machine it runs on, the same non-hermetic trade-off as build time.

`FFTW_FOUND` and `ROOT_FOUND` — preprocessor defines Katydid's own source checks with `#ifdef`
— are set as `defines` directly on the `@binary_deps//:fftw` and `@root//:root` targets, so
they propagate automatically to every target that depends on them, matching what
`add_definitions(-DFFTW_FOUND)` did project-wide in the CMake build.

`boost_system` is deliberately not linked: `Boost.System` has been header-only since Boost
1.69, and Boost 1.89 removed the compiled stub library outright, so linking it fails on any
current Boost installation.

## ROOT dictionary generation (`tools/root_dictionary.bzl`)

Three ROOT dictionaries are generated in this build: two Katydid modules (`Utility`, `IO`) and
Cicada, replacing CMake's `ROOT_GENERATE_DICTIONARY()`. This needs to be a real Starlark rule
rather than a plain `genrule`, because `rootcling` must see every header transitively reachable
from the dictionary headers (via Nymph, Scarab, Boost, and so on), and only a rule that reads
the `CcInfo` provider of its `deps` can obtain the actual transitive include paths Bazel already
knows about.

Each module using this exposes a headers-only `cc_library` (e.g. `katydid_utility_headers`)
purely so the dictionary rule has something to depend on for compilation-context purposes,
without creating a circular dependency (the real library's `srcs` include the generated
dictionary `.cxx`, so it cannot itself be the dictionary rule's dependency).

`rootcling` is invoked with header **basenames**, not full paths: with `-inlineInputHeader`,
whatever string is passed on the command line is embedded literally as the `#include` target
in the generated `.cxx`. A full path resolvable at generation time is not necessarily
resolvable later when that file is actually compiled from a different location under Bazel's
output tree; basenames combined with the correct `-I` flags resolve correctly in both places.
Note that `-inlineInputHeader` only inlines the headers it is directly given — it does not
recursively inline their own transitive `#include`s, which stay as literal, unexpanded text in
the generated payload (see below).

### Getting the generated `.pcm` file found at runtime

The generated `.pcm` file needs to be a runtime dependency, not just a build input. ROOT's
Cling interpreter looks for a dictionary's `.pcm` file **directly inside the same `bazel-out`
output directory as the consuming binary itself** — not via Bazel's runfiles tree, and not in
the package where the dictionary was originally generated.

`katydid_utility`, `katydid_io`, and `@cicada` each declare `data = [":<name>_pcm"]` on their
own `cc_library`. This alone is not sufficient for any consumer that lives in a different
Bazel package: a library's `data` only propagates the file into *that consumer's runfiles
tree*, which is a different location from the flat `bazel-out` directory Cling actually
searches — a consumer transitively depending on `katydid_io` and carrying that `data`
dependency can still fail with "ROOT PCM ... file does not exist".

The fix — needed in every package that builds a binary linking one of these libraries and
exercising the affected code path — is a `genrule` that copies the relevant dictionary's `.pcm`
into a plain output *in that consuming package*:

```python
genrule(
    name = "IODict_pcm_local_copy",
    srcs = ["//Source/IO:IODict_pcm"],
    outs = ["IODict_gen_rdict.pcm"],
    cmd = "cp $< $@",
)
```

listed as a `data` dependency of the actual binary or test. A `genrule`'s output is always
built directly into the package where the `genrule` itself is declared — never routed through
runfiles — so this lands exactly where Cling looks. This does not propagate automatically from
the defining library; it has to be repeated per consuming package. Both
`Source/Executables/Validation/BUILD.bazel` (for `IODict` and `CicadaDict`) and
`Source/Executables/Main/BUILD.bazel` (for `Katydid` and `Truncate`, which link `katydid_io`,
which itself depends on `@cicada`) carry this genrule.

Most code tolerates a missing PCM as a harmless "file does not exist" warning and falls back to
re-parsing the dictionary's own embedded header text at runtime instead — but classes actually
used via `TClonesArray` (`KTDiscriminatedPoint`/`KTSparseWaterfallCandidateData` from
`KTROOTData.hh`, and Cicada's `TProcessedTrackData`/`TMultiTrackEventData`) need the PCM for
real, for streamer-info lookup, and crash without it. A future binary or test that links
`katydid_io` or `@cicada` and writes ROOT trees containing these classes will need the same two
genrules copied into its own `BUILD.bazel`.

## Self-registering static initializers and `alwayslink`

Scarab's JSON and YAML codecs (`param_json.cc`, `param_yaml.cc`) self-register with Scarab's
own codec factory via a static global object whose constructor performs the registration — the
standard pattern for runtime dispatch by string name, so consuming code never needs a
compile-time reference to a specific codec class. This is exactly the situation Bazel's
selective static-library linking defeats: if nothing in a consumer directly references a symbol
from `param_json.o`/`param_yaml.o`, the linker is free to drop that object file entirely, and
the registrar's constructor never runs. Symptom: `"Did not find factory for <json>"` at
runtime, from code with no visible connection to codecs at all. Fixed by setting
`alwayslink = True` on `@scarab`'s `cc_library`, which forces every one of its object files
into every consumer, whether or not anything references it directly.

`@cicada`'s own dictionary registration does not need the same treatment. `rootcling` generates
a class's registration as a static global (`_R__UNIQUE_DICT_(Init) = GenerateInitInstance();`)
inside the dictionary `.cxx` itself — structurally the same shape of risk as Scarab's codecs, a
self-registering object in its own translation unit. The difference is what else references it:
Scarab's codec registration is purely string-dispatched, so nothing in ordinary code ever calls
into `param_json.o` directly, which is why it needs `alwayslink`. ROOT's `ClassDef` macro
instead generates `IsA()`, `Class()`, and `Streamer()` directly on the class, and these are what
ROOT's own I/O machinery calls whenever an object is actually streamed to a
`TTree`/`TClonesArray` — calling directly into functions defined in the dictionary `.cxx`.
Writing the class to a ROOT file, the only reason to link `@cicada` at all, already forces that
reference.

## Known pre-existing issues in Katydid's source

Bugs in Katydid's source, independent of Bazel — worth fixing upstream, not routed around by
this build.

In library code:

- `Source/Utility/KTKatydidApp.hh` defines `GetTApplication()` out-of-class in the header
  without the `inline` keyword — a One Definition Rule violation that only manifests when
  statically linking (as Bazel's default `cc_library` does), not when linking against a shared
  library (as the original CMake build, with `BUILD_SHARED_LIBS ON`, does).
- `Source/Utility/KTDemangle.hh` (a free function) and
  `Source/EventAnalysis/KTSpectrogramCollector.hh` (a method) have the same ODR violation — a
  definition sitting directly in a header without `inline`. Each surfaces only when a
  Validation test becomes a second translation unit compiling the same header.
- `Source/Utility/KTCutable.hh`'s `RangeIteratorEqualTo`/`RangeIteratorHash` inherited from
  `std::binary_function`/`std::unary_function`, both removed from modern libc++;
  `boost::unordered_map` only actually needs `operator()`.
- `Source/Utility/KTSpline.hh` declares `Implement()` returning
  `std::shared_ptr<Implementation>`. `KTSpline.cc` matches this under `#ifdef ROOT_FOUND` — the
  only configuration this build ever compiles — but not in the `#else` branch, which returns a
  raw `KTPhysicalArray<1,double>*` instead.

In `Source/Executables/Validation` test files:

- `TestConvolution1D.cc` hardcodes an absolute path
  (`/Users/ezayas/Katydid/Examples/CustomApplications/GaussianKernel.json`) to a sample kernel
  file, with a comment reading "You'll need to change this to your own path" — not meant to run
  unattended. References the file with a relative path and a `data` dependency instead (see
  `Examples/CustomApplications/BUILD.bazel`).
- `TestSequentialTrackFinder.cc` unconditionally dereferences `itccandidates.begin()` before
  writing a candidate to a ROOT tree, without checking whether the set is empty. With this
  test's synthetic data and clustering parameters, the set is empty on every run, making
  `.begin() == .end()`; dereferencing that is undefined behavior, manifesting as a `shared_ptr`
  constructed from garbage that crashes when its reference count is incremented.
- `TestWignerVille.cc` has three separate bugs: it initializes the forward FFT for
  real-as-complex data with `InitializeForRealTDD()` instead of
  `InitializeForRealAsComplexTDD()`; it never calls `KTWignerVille::Initialize()`, so
  `TransformData()` fails on every call; and its `KTAnalyticAssociateData` is stack-allocated
  inside the processing loop, whose destructor recursively deletes chained extensible-struct
  data — a use-after-free deferred until the post-loop ROOT-writing code actually reads from it.

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

## The Validation test suite (`Source/Executables/Validation/BUILD.bazel`)

Every program in Katydid's original `Source/Executables/Validation/CMakeLists.txt` has been
ported to a `cc_test`, grouped into the same tiers the original file used (by which Katydid
modules each tier's programs depend on), with two exceptions:

- `TestDataDisplay` is excluded entirely: it launches an interactive ROOT GUI and cannot run
  unattended.
- `Test2DDiscrim` is excluded: it directly constructs a `KTSpline` object (see `KTSpline`
  above). Its portability given `KTSpline.cc`'s current inclusion in the build is unverified.

Most of these tests are smoke tests only — they run a processing pipeline on synthetic data and
check that nothing crashes, without asserting on specific output values. A few check for a
specific internal error condition (see the comment above the `TestChannelAggregator` block in
the BUILD file for exactly which). This behavior reflects the tests exactly as CMake ran them.

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
that are not present by default on a fresh container or runner image (`libtbb`, `libxxhash`,
`libfreetype`, `libgsl`) — on AlmaLinux, `tools/almalinux_libs.bzl` fetches these hermetically
as part of the Bazel build itself (see the section above), so nothing needs installing via `dnf`
for them; both CI jobs also include a step that runs `ldd` against a built test binary
(`TestVector`) to catch any missing shared library in one clear failure rather than discovered
one Bazel build at a time.

Both `bazel build //...` and `bazel test //...` are run explicitly, rather than just the
latter: `bazel test` with `--build_tests_only` (the default from Bazel 8.2.0 onward) does not
build non-test targets, which would otherwise leave `Katydid`/`Truncate` unbuilt in CI.

`.github/workflows/lockfile-sync.yaml` keeps `MODULE.bazel.lock` up to date on pull requests
opened by Renovate. It needs the same Boost/FFTW/MatIO provisioning as the main CI job's Ubuntu
path, because `bazel mod deps` evaluates every module extension declared in `MODULE.bazel` —
including `tools/ubuntu_libs.bzl` — to compute the lockfile, and that extension hard-fails
without them actually present. `tools/root.bzl`'s extension needs no equivalent provisioning:
it fetches ROOT directly from root.cern regardless of what's on the runner.

## Known limitations / possible future work

- `Test2DDiscrim` (see "The Validation test suite" above) has not been checked for portability
  given `KTSpline.cc`'s current inclusion in the build.
- Boost, FFTW, and MatIO are not built hermetically on macOS or Ubuntu; the exact versions used
  there depend on what is installed on the host (see "How ROOT, Boost, FFTW, and MatIO are
  located" above). On AlmaLinux they are pinned and fetched hermetically
  (`tools/almalinux_libs.bzl`). ROOT is pinned everywhere (`tools/root.bzl`'s `_ROOT_VERSION`)
  and fetched by Bazel itself, independent of the host. `MODULE.bazel.lock` only pins the Bazel
  Central Registry dependencies (`rules_cc`, `platforms`).
- A shared HPC cluster deployment (no root/administrator access for ordinary users) has not
  been built out. On macOS/Ubuntu, the likely approach would be a minimal package-manager
  request to a cluster administrator for the packages `tools/macos_libs.bzl`/
  `tools/ubuntu_libs.bzl` need, plus a user-writable ROOT tarball installation (not `/opt`, which
  ordinary users typically cannot write to) - though AlmaLinux clusters need no such request at
  all, since `tools/almalinux_libs.bzl` fetches everything hermetically already. Worth checking
  first whether the cluster already provides these via CVMFS or an environment module system,
  which could reduce or eliminate the administrator request entirely on macOS/Ubuntu.
- Boost, FFTW, and MatIO could in principle be built hermetically by Bazel on macOS/Ubuntu too,
  instead of relying on the system package manager — `rules_boost` (which pairs Boost's source
  with hand-written native `cc_library` build files, avoiding Boost's own `b2` build system) is
  the natural starting point for Boost specifically. ROOT is a much larger undertaking and not
  recommended: a full source build is slow, and there is no maintained "ROOT for Bazel" project
  to build on.
- `//:katydid_release`'s packaged archive layout is `bin/` (portable wrapper scripts execing
  RPATH-patched real binaries), `lib/` (every Katydid/Cicada/Nymph/Scarab/yaml-cpp `.so` and
  dictionary PCM, harvested automatically from the binaries' runfiles — see
  `Source/Executables/Main/harvest_runtime_libs.bzl` — plus, on AlmaLinux only, Boost/FFTW/MatIO
  and the TBB/xxhash/FreeType/GSL ROOT-runtime extras, since those are fetched hermetically
  there), `root/` (ROOT's tarball, bundled wholesale and kept separate from `lib/`, since ROOT's
  runtime needs a real, intact install layout to find `etc/gitinfo.txt` and `dlopen()`-load
  `libCling.so`), and `include/` (currently just the six Cicada headers `CicadaDict`'s
  dictionary payload `#include`s by bare filename — the specific set needed for Cling's
  autoparse to succeed rather than fail outright on a TClonesArray-backed write). Not yet done:
  on macOS/Ubuntu, Boost/FFTW are still resolved via plain system linker paths at archive-build
  time, not bundled into the archive itself, so the target machine still needs them installed;
  every other Katydid/Nymph/Scarab header isn't bundled or flattened into a single
  `include/Katydid/` the way the CMake install does, so the archive isn't yet usable as a
  build-against dependency for downstream code; and while `bazel build //...` builds
  `//:katydid_release` (RPATH-patching included) on all three CI platforms, nothing extracts the
  resulting archive and actually runs the binary from it, on either Linux or macOS - so the
  patched RPATHs' correctness is never verified end-to-end.
