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
  none of them have native Bazel support upstream. Also applies two source patches to Scarab
  (see "Known pre-existing issues" below).
- `tools/system_deps.bzl` — locates ROOT, Boost, FFTW, and MatIO on the host machine and exposes
  them as `cc_library` targets under the repository name `@system_libs`.
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

## How ROOT, Boost, FFTW, and MatIO are located

`tools/system_deps.bzl` implements a single repository rule, exposed as `@system_libs`, that
branches on the host platform:

- **ROOT** is located identically on every platform: by requiring `root-config` to already be
  on `PATH`. This works whether ROOT came from Homebrew, a manually-extracted binary tarball, or
  any other installation method, since `root-config` is ROOT's own official query tool and every
  ROOT distribution ships one. The rule queries `root-config --incdir`, `--libdir`, and
  `--libs`, and adds `-lGui -lSpectrum -lTMVA` on top of the base libraries, matching Katydid's
  `find_package(ROOT 6.00 COMPONENTS Gui Spectrum TMVA)` in the original CMake build. `rootcling`
  is located via `root-config --bindir` and exposed as `@system_libs//:rootcling`.
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

`FFTW_FOUND` and `ROOT_FOUND` — preprocessor defines Katydid's own source checks with `#ifdef`
— are set as `defines` directly on the `@system_libs//:fftw` and `@system_libs//:root` targets,
so they propagate automatically to every target that depends on them, matching what
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

The generated `.pcm` file needs to be a runtime dependency, not just a build input — but making
that work correctly took real trial and error, and the mechanism is easy to get wrong in a way
that looks like it should work. ROOT's Cling interpreter looks for a dictionary's `.pcm` file
**directly inside the same `bazel-out` output directory as the consuming binary itself** — not
via Bazel's runfiles tree, and not in the package where the dictionary was originally
generated.

`katydid_utility`, `katydid_io`, and `@cicada` each declare `data = [":<name>_pcm"]` on their
own `cc_library`, matching the natural first instinct ("this library owns the dictionary, so
the library should carry the runtime dependency"). This is not sufficient for any consumer
that lives in a different Bazel package: a library's `data` only propagates the file into
*that consumer's runfiles tree*, which is a different location from the flat `bazel-out`
directory Cling actually searches. Confirmed the hard way: `TestTrackProcessing` and
`TestSequentialTrackFinder` (in `Source/Executables/Validation/`) both transitively depend on
`katydid_io` and therefore already had this `data` dependency, and both still crashed with
"ROOT PCM ... file does not exist" until a second, package-local fix was added.

That fix — needed in every package that builds a binary linking one of these libraries and
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
runfiles — so this lands exactly where Cling looks. There is no way to make this propagate
automatically from the defining library; it has to be repeated per consuming package. Both
`Source/Executables/Validation/BUILD.bazel` (for `IODict` and `CicadaDict`) and
`Source/Executables/Main/BUILD.bazel` (for `Katydid` and `Truncate`, which link `katydid_io`,
which itself depends on `@cicada`) now carry this genrule.

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

Whether `@cicada`'s own dictionary registration needs the same treatment was an open question,
now resolved: it does not. `rootcling` generates a class's registration as a static global
(`_R__UNIQUE_DICT_(Init) = GenerateInitInstance();`) inside the dictionary `.cxx` itself —
structurally the same shape of risk as Scarab's codecs, a self-registering object in its own
translation unit. The difference is what else references it: Scarab's codec registration is
purely string-dispatched, so nothing in ordinary code ever calls into `param_json.o` directly,
which is exactly why it got dropped. ROOT's `ClassDef` macro instead generates `IsA()`,
`Class()`, and `Streamer()` directly on the class, and these are what ROOT's own I/O machinery
calls whenever an object is actually streamed to a `TTree`/`TClonesArray` — calling directly
into functions defined in the dictionary `.cxx`. Writing the class to a ROOT file, the only
reason to link `@cicada` at all, already forces the same reference Scarab's codecs never got.
Confirmed empirically, not just by this reasoning: `TestROOTDictionary.cc` can't be used to
verify this (see above), but
`Source/Executables/Validation/TestROOTTreeWritingViaCicada.cc` is its own isolated binary that
actually calls `WriteProcessedTrack`/`WriteMultiTrackEvent` and passes — if the registration
weren't linked in, that streaming call should fail outright, not just log a warning.

## Known pre-existing issues in Katydid's source

Bugs found in the process of porting the build, independent of Bazel — worth fixing upstream,
not routed around by this build.

In library code:

- `Source/Utility/KTKatydidApp.hh` defines `GetTApplication()` out-of-class in the header
  without the `inline` keyword — a One Definition Rule violation that only manifests when
  statically linking (as Bazel's default `cc_library` does), not when linking against a shared
  library (as the original CMake build, with `BUILD_SHARED_LIBS ON`, does). Fixed by adding
  `inline`.
- `Source/Utility/KTDemangle.hh` (a free function) and
  `Source/EventAnalysis/KTSpectrogramCollector.hh` (a method) have the same ODR violation as
  above — a definition sitting directly in a header without `inline`. Each surfaced only once a
  Validation test happened to be the second translation unit compiling the same header
  alongside the library itself. Both fixed the same way.
- `Source/Utility/KTCutable.hh`'s `RangeIteratorEqualTo`/`RangeIteratorHash` inherited from
  `std::binary_function`/`std::unary_function`, both removed from modern libc++. Fixed by
  dropping the inheritance; `boost::unordered_map` only actually needs `operator()`.
- `Source/Utility/KTSpline.hh` declares `Implement()` returning
  `std::shared_ptr<Implementation>`. `KTSpline.cc` matches this under `#ifdef ROOT_FOUND` — the
  only configuration this build ever compiles — but not in the `#else` branch, which returns a
  raw `KTPhysicalArray<1,double>*` instead. `KTSpline.cc` was originally excluded from the
  build over this mismatch, based on a reading of the file that didn't separate the two
  branches; it is now included, since the branch this build actually uses is correct.

In `Source/Executables/Validation` test files:

- `TestConvolution1D.cc` hardcoded an absolute path
  (`/Users/ezayas/Katydid/Examples/CustomApplications/GaussianKernel.json`) to a sample kernel
  file, with a comment reading "You'll need to change this to your own path" — this test was
  never meant to run unattended. Fixed by referencing the file with a relative path and adding
  it as a `data` dependency (see `Examples/CustomApplications/BUILD.bazel`, which did not exist
  as a Bazel package at all before this).
- `TestSequentialTrackFinder.cc` unconditionally dereferenced `itccandidates.begin()` before
  writing a candidate to a ROOT tree, without checking whether the set was empty. With this
  test's synthetic data and clustering parameters, the set is empty on every run, making
  `.begin() == .end()`; dereferencing that is undefined behavior, which manifested as a
  `shared_ptr` constructed from garbage, crashing when its reference count was incremented. An
  `lldb` backtrace was needed to find this: the crash occurred in the log immediately after a
  ROOT dictionary autoload warning, which was initially (and incorrectly) suspected as the
  cause before the actual backtrace pointed to this line instead.
- `TestWignerVille.cc` had three separate bugs: it initialized the forward FFT for
  real-as-complex data with `InitializeForRealTDD()` instead of
  `InitializeForRealAsComplexTDD()`; it never called `KTWignerVille::Initialize()`, so
  `TransformData()` failed on every call; and its `KTAnalyticAssociateData` was stack-allocated
  inside the processing loop, whose destructor recursively deletes chained extensible-struct
  data — a use-after-free deferred until the post-loop ROOT-writing code actually read from it.
  All three fixed directly in the test file.

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
- `Test2DDiscrim` is excluded: it directly constructs a `KTSpline` object, whose constructor
  was undefined at the time this tier was ported (see `KTSpline` above). `KTSpline.cc` has
  since been re-included in the build; this test has not been revisited since and may now be
  portable without further work.

Most of these tests are smoke tests only — they run a processing pipeline on synthetic data and
check that nothing crashes, without asserting on specific output values. A few do check for a
specific internal error condition (see the comment above the `TestChannelAggregator` block in
the BUILD file for exactly which). None of this behavior was written or changed as part of the
Bazel port; it reflects the tests exactly as CMake ran them.

This directory is also where every bug listed above under "Known pre-existing issues" was
actually found: Katydid's CMake build had evidently not been exercising most of these programs
for long enough that straightforward compile errors, undefined behavior, and missing runtime
dependencies had accumulated undetected.

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

Both `bazel build //...` and `bazel test //...` are run explicitly, rather than just the
latter: `bazel test` with `--build_tests_only` (the default from Bazel 8.2.0 onward) does not
build non-test targets, which would otherwise leave `Katydid`/`Truncate` unbuilt in CI.

`.github/workflows/lockfile-sync.yaml` keeps `MODULE.bazel.lock` up to date on pull requests
opened by Renovate. It needs the same system-library provisioning as the main CI job's Ubuntu
path, because `bazel mod deps` evaluates every module extension declared in `MODULE.bazel` —
including `tools/system_deps.bzl` — to compute the lockfile, and that extension hard-fails
without Boost/FFTW/MatIO/ROOT actually present.

## Known limitations / possible future work

- `Test2DDiscrim` (see "The Validation test suite" above) is excluded for a reason that no
  longer holds now that `KTSpline.cc` is back in the build; revisiting it just hasn't happened
  yet.
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
