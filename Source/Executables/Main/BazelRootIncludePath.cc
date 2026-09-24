// Bazel-only: sets ROOT_INCLUDE_PATH before IODict/CicadaDict's own static initializer runs
// (the one that calls TCling::RegisterModule), so Cling's runtime autoloader
// (cling::AutoLoadingVisitor) can find Cicada's dictionary header (_CROOTData.hh) when it
// first encounters a type like Cicada::TProcessedTrackData/TMultiTrackEventData. Without
// this, autoloading fails with "Missing FileEntry for _CROOTData.hh" -- confirmed non-fatal,
// but avoidable.
//
// This file is deliberately NOT listed in Source/Executables/Main/CMakeLists.txt. CMake
// doesn't need this fix: it builds in-place against a persistent checkout, so the header is
// always just sitting on disk at its normal source location, and Cling finds it without any
// help. Bazel's hermetic runtime model is what makes this necessary here specifically -- see
// the corresponding BUILD.bazel comment for the full explanation.
//
// Compiled directly into //Source/Executables/Main:libroot_dict_shared.so (not Katydid/
// Truncate): IODict/CicadaDict's own static initializer -- the one that actually needs
// ROOT_INCLUDE_PATH set -- runs as part of that same .so's own load, which is guaranteed by
// the ELF spec to complete before Katydid/Truncate's own static initializers even start
// (a shared library's own dependencies' initializers always run before its own; confirmed
// directly against glibc's own documentation, not assumed). This file used to live in
// Katydid/Truncate directly, back when the dictionary's own code did too, relying on ELF's
// only weaker guarantee for that arrangement -- that every initializer in one binary,
// cross-translation-unit order unspecified, completes before main() begins -- which happened
// to put this before the dictionary's own initializer, but was never actually guaranteed to.
//
// Runs via an explicit __attribute__((constructor(priority))), not the file's own global
// object whose constructor happens to run implicitly, precisely because it must run before
// the dictionary's own (unprioritized) static initializer within this same .so -- and
// cross-translation-unit order for two ordinary, unprioritized initializers in one binary is
// exactly as unspecified here as it was for the old Katydid/Truncate arrangement above. GCC
// and Clang both guarantee constructors with an explicit priority run before any without one,
// regardless of link order -- this is the one thing here that's a real guarantee, not luck.
//
// A plain cc_binary's own direct sources aren't subject to unreferenced-object dead code
// stripping the way a cc_library dependency can be, so no alwayslink equivalent is needed
// for this to always link in.
//
// Deliberately does NOT use Bazel's runfiles library. CicadaDict_header_local_copy (see
// BUILD.bazel) already places _CROOTData.hh directly alongside Katydid/Truncate themselves,
// in the same bazel-out directory both live in -- not just in the runfiles tree. So all this
// needs is the directory containing the currently-running executable (not this .so's own
// location, which /proc/self/exe and _NSGetExecutablePath both already resolve to regardless
// of which shared library the calling code happens to live in), which requires no runfiles
// machinery at all, and keeps this working correctly for a plain packaged/relocated copy of
// the binary (release archives, etc.) that doesn't bring a .runfiles tree along.

#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#elif defined(__linux__)
#include <unistd.h>
#include <climits>
#endif

namespace
{
    [[noreturn]] void Die(const std::string& message)
    {
        std::cerr << "[BazelRootIncludePath] FATAL: " << message << "\n";
        std::exit(1);
    }

    // Returns the absolute path to the currently-running executable. Independent of
    // argv[]/argc entirely (this runs from a constructor, before main(), so argv[] isn't
    // available yet) -- these are OS-level APIs answering "what file is actually loaded and
    // running as this process", not "what path was I invoked with".
    std::string GetExecutablePath()
    {
#if defined(__APPLE__)
        uint32_t size = 0;
        _NSGetExecutablePath(nullptr, &size);  // always returns -1 here; sets size
        std::vector<char> buffer(size);
        if (_NSGetExecutablePath(buffer.data(), &size) != 0)
        {
            Die("_NSGetExecutablePath failed on the second (correctly-sized) call");
        }
        return std::string(buffer.data());
#elif defined(__linux__)
        char buffer[PATH_MAX];
        const ssize_t len = readlink("/proc/self/exe", buffer, sizeof(buffer) - 1);
        if (len == -1)
        {
            Die("readlink(/proc/self/exe) failed");
        }
        buffer[len] = '\0';
        return std::string(buffer);
#else
        Die("GetExecutablePath: no implementation for this platform");
#endif
    }

    void SetRootIncludePathForCicadaAutoloading()
    {
        const std::string executablePath = GetExecutablePath();

        const std::size_t lastSlash = executablePath.find_last_of('/');
        if (lastSlash == std::string::npos)
        {
            Die("executable path has no '/': <" + executablePath + ">");
        }
        const std::string executableDir = executablePath.substr(0, lastSlash);

        // Append to, rather than replace, any pre-existing ROOT_INCLUDE_PATH (e.g. one
        // set manually for interactive/debug use), so both take effect.
        const char* existing = std::getenv("ROOT_INCLUDE_PATH");
        std::string newValue = executableDir;
        if (existing != nullptr && existing[0] != '\0')
        {
            newValue = std::string(existing) + ":" + executableDir;
        }
        if (setenv("ROOT_INCLUDE_PATH", newValue.c_str(), /*overwrite=*/1) != 0)
        {
            Die("setenv(ROOT_INCLUDE_PATH) failed");
        }
        std::cerr << "[BazelRootIncludePath] Set ROOT_INCLUDE_PATH to: " << newValue << "\n";
    }

    // 200 is arbitrary beyond being valid (GCC/Clang require 101-65535, lower runs earlier) --
    // there's nothing else in this .so competing for an early slot, so nothing here depends on
    // the exact number, only on it being lower priority (numerically) than IODict/CicadaDict's
    // own unprioritized initializer, which is guaranteed for any explicit priority at all.
    [[gnu::constructor(200)]] void RunSetRootIncludePathForCicadaAutoloading()
    {
        SetRootIncludePathForCicadaAutoloading();
    }
}
