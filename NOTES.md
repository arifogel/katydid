# Bazel port of Katydid (feature/FreqDomainInput) — status

## Where to put these files

Drop this tree directly on top of your `katydid` checkout root (i.e. `MODULE.bazel` sits
next to the existing `CMakeLists.txt`, `Source/Utility/BUILD.bazel` sits next to the
existing `Source/Utility/CMakeLists.txt`, etc). Nothing here touches or requires the
existing CMake build — they coexist.

## Pinned commits (from `git submodule status` on feature/FreqDomainInput)

```
329b058736771038c150933bc275448ca5f24245  Cicada   (v1.3.2-1-g329b058)
f3697b89f345894bc20c2c2d07fd553aa3b22de2  Nymph    (v1.4.7)
ef2af248c5db7c92c84952a57759ba0f145f6cd4  Scarab   (pinned identically by both Nymph and Cicada)
5de06bfa37495b529dc00139f1b138a526fff27a  rapidjson (pinned by Scarab)
3757b2023b71d183a341677feee693c71c2e0766  yaml-cpp  (pinned by Scarab)
```

`Source/Time/Monarch` is intentionally not fetched — `Katydid_USE_MONARCH` is OFF by
default and nothing outside its own `#ifdef` block touches it.

## What's actually been verified

I don't have macOS or a ROOT/Boost install available where I did this work, so I
derisked the thing most likely to silently break — whether this ~2018-era code compiles
against **modern** Boost — by hand-compiling the real dependency chain on Linux with
Boost 1.83 (close to what current Homebrew ships) and g++:

- Scarab: `utility`, `logger`, `param`, `param/codec/json` (against real rapidjson at the
  pinned commit)
- Nymph: `Utility`, and `Application/{KTApplication,KTCommandLineHandler,KTConfigurator}.cc`
- Katydid: `Source/Utility` (all files except `KTSpline.cc`, see bug below)

All of it compiled clean and **linked** into a working binary with nothing more exotic
than `-lboost_* -lpthread -lfftw3`. That's the main risk from switching off the
CentOS6/old-Boost Docker toolchain, and it didn't materialize — good sign for the rest of
the port.

**Not yet compile-tested:** `yaml-cpp`, Nymph's `Data`/`Processor`/`IO` (only
`Application`+`Utility` were exercised), and obviously everything ROOT-dependent (all of
Cicada, and the four ROOT-dictionary spots in Katydid). Source lists for the untested
Nymph pieces were copied exactly from `Library/CMakeLists.txt`, not guessed, so they
should be right, but "should be" isn't "verified."

## A real bug this surfaced, unrelated to Bazel

`Source/Utility/KTSpline.hh` declares:
```cpp
std::shared_ptr<Implementation> Implement(unsigned nBins, double xMin, double xMax) const;
```
but `Source/Utility/KTSpline.cc` still defines the old signature:
```cpp
KTPhysicalArray<1, double>* KTSpline::Implement(unsigned nBins, double xMin, double xMax) const
```
This won't compile under any toolchain — looks like a half-finished refactor on this
branch. `KTSpline.cc` is excluded from `Source/Utility/BUILD.bazel` until it's fixed;
re-add it to `srcs` once it is.

## Fixes applied after the first round of `bazel build` errors (Bazel 9)These were real gaps, all now fixed in this tree:

- `cc_library`/`cc_binary`/etc. were removed from Bazel core in the Bazel 9 cleanup (same
  effort that finished removing `WORKSPACE`) and now live only in `rules_cc`. Every
  `BUILD.bazel`/`BUILD.*.bazel` file needs
  `load("@rules_cc//cc:cc_library.bzl", "cc_library")` — this includes the *generated*
  BUILD file `tools/homebrew.bzl` writes at fetch time, which is easy to miss since you
  never see that file directly.
- `platforms` needed bumping to `1.0.0` in `MODULE.bazel` — `rules_cc@0.2.22` transitively
  wants `platforms@1.0.0`+, and Bazel's `--check_direct_dependencies` (on by default)
  flags the mismatch against the pin here rather than silently upgrading it.
- Every directory referenced by a Bazel *label* — including `.bzl` files loaded via
  `load("//tools:non_bazel_deps.bzl", ...)`, and `git_repository`'s `build_file =
  "//third_party/nymph:BUILD.nymph.bazel"` attribute — needs a real (can be empty)
  `BUILD.bazel` in that directory to mark it as a package. `tools/`,
  `third_party/nymph/`, `third_party/scarab/`, `third_party/rapidjson/`,
  `third_party/yaml_cpp/` all needed one.
- `tools/homebrew.bzl`'s per-formula `hdrs = glob(...)` had no `allow_empty = True`, so any
  *one* not-yet-installed/not-yet-used formula (this bit us on `matio`, added preemptively
  for a later module, before anyone actually installed `libmatio`) failed to load the
  entire `@homebrew` package - since it's one repo with one generated `BUILD.bazel`
  covering boost+fftw+matio+root together, that took down `boost`/`fftw`/`root` too, with
  a wall of misleading "contains an error, referenced by..." messages burying the one real
  glob error. Fixed with `allow_empty = True` - an unused/uninstalled formula now just
  produces an empty library instead of an unrelated cascade; actually trying to *use* it
  unset gives a normal, isolated missing-header compile error instead.
- `tools/root_dictionary.bzl`'s `_rootcling` attr used `executable = True`, which requires
  the referenced label to be a build rule producing a `FilesToRunProvider` - `@homebrew//:rootcling`
  is a plain source file (symlinked in via `exports_files()`), so this failed with "is
  misplaced here (expected no files)" the first time anything actually tried to build a
  dictionary. Fixed by switching to `allow_single_file = True` + `ctx.file._rootcling`,
  which `ctx.actions.run()`'s `executable=` parameter accepts directly.
- Same underlying issue as `CcInfo` earlier, but for `cc_common` itself: the bare global
  `cc_common` in Bazel 9 is a stripped internal stub (no `merge_cc_infos`, confirmed by the
  actual error's "Available attributes" list) - needs `load("@rules_cc//cc/common:cc_common.bzl",
  "cc_common")` same as `CcInfo` needed its own load.

## Cicada: real content bugs found once it actually got to compiling (not Bazel plumbing)

With C++17 and the two loads above fixed, `rootcling` genuinely ran and generated
`CicadaDict_gen.cxx` - real confirmation the dictionary macro itself works. Two content
bugs surfaced past that point, both now fixed in this tree:

1. **`_CROOTData.cc` wasn't visible in the sandbox.** `CROOTData.cc` does `#include
   "_CROOTData.cc"` (an old "private implementation file, included not separately
   compiled" idiom - it was never in `CICADA_SOURCEFILES` in the original CMakeLists.txt
   either, consistent with this). Bazel's sandboxing only exposes files declared as
   `srcs`/`hdrs`, and `hdrs = glob(["Library/*.hh"])` doesn't match a `.cc` file. Fixed by
   explicitly adding `"Library/_CROOTData.cc"` to `hdrs` on both `cicada_headers` and
   `cicada`.
2. **`root_dictionary.bzl` passed full execroot-relative paths to `rootcling` for the
   header arguments.** With `-inlineInputHeader`, rootcling embeds whatever string it's
   given literally as the `#include` target in the generated `.cxx` - a path like
   `external/+non_bazel_deps+cicada/Library/Foo.hh` doesn't resolve when that generated
   file is later compiled from a different location under `bazel-out/`. Fixed by passing
   bare basenames (`h.basename`) instead, relying on the `-I` flags (already correct) for
   both `rootcling`'s own header lookup and the later real compile to find them - this
   matches how CMake's own `ROOT_GENERATE_DICTIONARY` invokes `rootcling` too.


## What still needs building (in order)

1. ~~`root_dictionary.bzl`~~ — **done and verified for real**, against actual ROOT via
   Homebrew on Apple Silicon (ROOT 6.38/6.40). `bazel build //Source/Utility:katydid_utility`
   with `--disk_cache=` (forcing everything to actually execute rather than replay from
   cache) completed with `92 processes: 8 internal, 84 darwin-sandbox` — real `rootcling`
   invocation, real compile of its output, real link. `Source/Utility` is fully done,
   including `KTRootGuiLoop.cc` and the `UtilityDict` dictionary.
2. ~~Cicada~~ — **done and verified for real**, including a from-clean, no-disk-cache
   build (confirming nothing was riding on stale cache from the earlier debugging rounds).
   Turns out Cicada needs no Nymph at all (checked its actual `#include`s) — only
   `@scarab` (`logger.hh`, `_member_variables.hh`) and `@homebrew//:root`. Katydid's
   top-level CMakeLists sets `Cicada_ENABLE_KATYDID_NAMESPACE FALSE` (overriding Cicada's
   own default of ON), so the `KTROOTData`/`CicadaKTDict` half is deliberately left out —
   matches the actual Katydid config, not Cicada's standalone default. The private
   `.cc`-include idiom that bit `CROOTData.cc` doesn't recur elsewhere in Katydid's own
   `Source/` tree (`grep -r '#include ".*\.cc"' Source` returns nothing) — one less thing
   to watch for in the remaining modules.
3. **The remaining Katydid `Source/*` modules** → matching `BUILD.bazel` files, same
   mechanical translation as `Source/Utility/BUILD.bazel`. `Transform`, `IO`, and
   `EventAnalysis` each need their own `root_dictionary()` call the same way `Utility` did.
   - `Data` — **done, verified for real** (`bazel build //Source/Data:katydid_data`
     succeeded). `vendor/nanoflann/BUILD.bazel` added too (a real target now, not a raw
     file reference). Fixed two latent bugs that hadn't surfaced yet: `FFTW_FOUND` was
     never actually defined anywhere (Utility never hit the code path that checks it —
     `Data/Time/KTPhysicalArrayFFTW.hh` does), and `ROOT_FOUND` was being set by hand
     per-target instead of once at the source. Both now live as `defines` directly on
     `@homebrew//:fftw` / `@homebrew//:root` in `tools/homebrew.bzl`, so they propagate
     transitively to every dependent automatically — `Source/Utility/BUILD.bazel`'s
     redundant manual `"ROOT_FOUND"` was removed accordingly.
   - **`Time`, `Simulation`, `Evaluation` — confirmed orphaned, not being ported.** The
     top-level `CMakeLists.txt` itself has `#add_subdirectory (Source/Time)`,
     `#add_subdirectory (Source/Simulation)`, `#add_subdirectory (Source/Evaluation)` —
     all three commented out. This isn't a guess or something broken by this port; the
     real upstream build already excludes them. (Independently, both had real content
     bugs anyway: `Simulation/KTTSGenerator.cc` includes a `thorax.hh` that doesn't exist
     anywhere in the repo; `Evaluation/KTCompareCandidates` depends on classes in
     `Source/Data/Evaluation/`, itself commented out of `Data/CMakeLists.txt`'s own
     source list, and calls non-inline methods on them that would likely fail to *link*
     even if it compiled. Consistent with both being genuinely dead code, not just
     temporarily disabled.) `SpectrumAnalysis` does NOT depend on `Time` — only on `IO`
     and `Transform` (both still to come), despite `Time` sitting nearby in the source
     tree.
   - **Real remaining scope, now that the dead branches are pruned:** `IO`, `Transform`,
     `EventAnalysis` (the dictionary trio — next batch), then `SpectrumAnalysis` (needs
     `IO` + `Transform`), then `Executables/Main` for the actual `Katydid`/`Truncate`
     binaries. Four modules, not twelve.

## IO / Transform / EventAnalysis — done, NOT yet built/tested

Turned out only **`IO`** actually needs `root_dictionary()` in this branch — `Transform`'s
and `EventAnalysis`'s `ROOT_GENERATE_DICTIONARY` calls are both fully commented out in their
real `CMakeLists.txt` (confirmed by reading the file, not just grepping for the macro name -
an earlier grep for "ROOT_GENERATE_DICTIONARY" matched the commented-out lines too and
overstated the risk). So `IO` got the full Utility/Cicada-style treatment
(`*_headers` target + `root_dictionary()` + real `cc_library`); `Transform` and
`EventAnalysis` are structurally more like `Data` - straightforward source-list
translation, no dictionary macro involved.

**Real dependency order, not the order CMakeLists.txt happens to list them in:** `IO` only
needs `Utility` + `Data` (+ `@cicada//:cicada`, + vendored `RapidXML` - see below) and can
be tested standalone. `Transform` and `EventAnalysis` both list `KatydidIO` in their own
`KATYDID_LIBS`, so neither is testable until `IO` actually builds, regardless of how simple
their own `BUILD.bazel` content is. Test `//Source/IO:katydid_io` first.

New vendored dependency: `IO/KTDPTReader.cc` uses `rapidxml.hpp`/`rapidxml_utils.hpp` -
added `vendor/RapidXML/BUILD.bazel` (same pattern as `vendor/nanoflann`).

New cross-repo dependency: `IO/Conversions/KT2ROOT.cc` is the only file that touches Cicada
directly (`CClassifierResultsData.hh` etc.) - `@cicada//:cicada` added to `IO`'s deps.

Confirmed safe to exclude, matching the real, active build config (not just "off by
default" flags I'm trusting blind):
- `HDF5Writer/*` - `Katydid_USE_HDF5`'s entire block is commented out at the top level of
  the real `CMakeLists.txt`, so `HDF5_FOUND` is never true regardless of what's installed.
- `ImageWriter/*` - `Katydid_USE_MAGICKPP` off by default, never enabled.
- `IO/KTSpec1Reader.cc/.hh` (needs Monarch's `M3*.hh` headers) - was never in
  `IO_SOURCEFILES` to begin with, independent of the Monarch question entirely.
- `EventAnalysis/KTDLIBClassifier.cc/.hh` - gated on `DLIB_FOUND`, never true
  (`Katydid_USE_DLIB` off by default); confirmed by inspection that `dlib/*.h` usage is
  confined to exactly this one file, so excluding it doesn't strand anything else.

Include-path style: IO's writer subdirectories (`BasicAsciiWriter`, `JSONWriter`, etc.) and
EventAnalysis's `CutClasses/` are each individually listed in the real top-level
`CMakeLists.txt`'s `include_directories()` block - meaning code elsewhere does e.g.
`#include "KTBasicROOTFileWriter.hh"` with no subdirectory prefix, not
`#include "BasicROOTFileWriter/KTBasicROOTFileWriter.hh"`. Mirrored exactly (each subdir
listed individually in `includes`) rather than assumed, since guessing wrong here would
produce `file not found` errors identical in shape to ones we've already chased down by
hand earlier in this port.

`TSpectrum.h` (EventAnalysis) and `TMVA/Reader.h` (EventAnalysis) showing up for real is a
nice confirmation that the `-lSpectrum -lTMVA` extra ROOT component libs added to
`@homebrew//:root` back when `tools/homebrew.bzl` was first written (based on Katydid's
`find_package(ROOT 6.00 COMPONENTS Gui Spectrum TMVA)`) were the right call, not
speculative - this is the first module that actually exercises them.

## SpectrumAnalysis and Executables/Main — the actual finish line

**`SpectrumAnalysis`** — done, NOT yet built/tested, but all four of its real dependencies
(`Utility`, `Data`, `IO`, `Transform`) are themselves now verified, so this is the least
speculative module written so far. No dictionary (never gated on ROOT for that in the first
place). `EIGEN3_FOUND` block (`KTBiasedACM`, `KTRQProcessor`) excluded - `Katydid_USE_EIGEN`
off by default, confirmed via `#include` inspection that `Eigen/*` usage is confined to
exactly those two files. The original `CMakeLists.txt` re-adds `KTConvolution.hh/.cc` and
`KTVariableSpectrumDiscriminator.hh/.cc` a second time under its `FFTW_FOUND`/`ROOT_FOUND`
blocks despite them already being unconditional - harmless CMake list duplication, each
listed once here.

**`Executables/Main`** — done, NOT yet built/tested. `cc_binary` targets for `Katydid` and
`Truncate`, both linking every module (`Utility`, `Data`, `IO`, `Transform`,
`EventAnalysis`, `SpectrumAnalysis`), matching the original `pbuilder_executables(programs
all_libs)` call exactly - not a simplification, `all_libs` there really is everything.
`EggScanner.cc`/`RSAMatToEgg.cc` excluded, both gated on Monarch (which this whole port
skips per the very first architectural decision). `Katydid.cc` itself is tiny - only
touches `KTKatydidApp.hh`/`KTLogger.hh`/`KTRunNymph.hh` directly, everything else comes in
through the library graph.

**This is the actual finish line for "does Katydid run."** These are the targets CLion's
Bazel plugin will expose as debuggable (lldb) run configurations.

4. **`cc_binary` targets** for `Source/Executables/Main/*` (`Katydid`, `Truncate`) — these
   are what CLion's Bazel plugin will expose as debuggable (lldb) run configurations. Note
   from `Source/Executables/Main/CMakeLists.txt`: the `Katydid` binary links against
   *every* module's library, so this is the last step, not something to reach for early.

## Real (non-Bazel-plumbing) bug found via Cicada's build

**ROOT requires C++17; this codebase was pinned to C++11.** Homebrew's ROOT (6.38/6.40)
hard-errors (`#error "ROOT requires support for C++17 or higher."`) when compiled under
`-std=c++11`, which `.bazelrc` set project-wide to match this ~2018-era codebase. Fixed by
bumping `.bazelrc` to `-std=c++17` globally (a strict superset for this code - nothing in
Nymph/Scarab/Katydid uses anything C++17 removed, and this is the same codebase already
smoke-tested clean against modern Boost) and removing the now-redundant `copts =
["-std=c++11"]` from every `BUILD.bazel`/`BUILD.*.bazel` that had one (`Source/Utility`,
`third_party/{nymph,scarab,yaml_cpp,cicada}`) - those would have overridden the global
bump on the actual compile line otherwise. `defines = ["USE_CPP11"]` stays as-is on
targets that had it - that's Katydid/Nymph/Scarab's own internal macro selecting their
C++11-compatible code paths (vs. an older C++98 path), unrelated to the compiler's actual
`-std=` flag.

## How to sanity-check this slice on your Mac

```sh
brew install boost fftw libmatio root   # if not already installed
cd katydid                              # wherever you dropped these files
bazel build //Source/Utility:katydid_utility
bazel build @cicada//:cicada
bazel build //Source/Data:katydid_data
bazel build //Source/IO:katydid_io          # test this before Transform/EventAnalysis
bazel build //Source/Transform:katydid_transform
bazel build //Source/EventAnalysis:katydid_event_analysis
bazel build //Source/SpectrumAnalysis:katydid_spectrum_analysis
bazel run //Source/Executables/Main:Katydid -- --help   # the actual finish line
```
First run will be slow (fetching Nymph/Scarab/rapidjson/yaml-cpp + resolving Boost via
`brew --prefix`); after that, editing any `.cc`/`.hh` under `Source/Utility` and
rebuilding should only recompile what changed — that's the "no stale artifacts, no
manual steps" property you asked for.

If `bazel build` complains about `rules_cc`/`platforms` version resolution, run
`bazel mod tidy` or bump the versions in `MODULE.bazel` — I picked current-as-of-writing
versions but the Bazel Central Registry moves fast enough that this could be stale by
the time you run it.
