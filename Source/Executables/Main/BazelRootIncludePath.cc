// Bazel-only: sets ROOT_INCLUDE_PATH before main() runs, so Cling's runtime autoloader
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
// Listed directly in Katydid/Truncate's own `srcs` (not behind an intermediate cc_library),
// so this always links in -- a static-initializer-only object with no other referenced
// symbols would otherwise risk being dropped as dead code from a `cc_library` dependency,
// the same class of bug fixed for KT_REGISTER_PROCESSOR et al. earlier in this project's
// bazel migration. A cc_binary's own direct sources aren't subject to that stripping, so no
// alwayslink equivalent is needed here.
//
// Deliberately does NOT use Bazel's runfiles library. CicadaDict_header_local_copy (see
// BUILD.bazel) already places _CROOTData.hh directly alongside the binary itself, in the
// bazel-out directory both live in -- not just in the runfiles tree. So all this needs is
// the directory containing the currently-running executable, which requires no runfiles
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
    // argv[]/argc entirely (this runs from a static initializer, before main(), so argv[]
    // isn't available yet) -- these are OS-level APIs answering "what file is actually
    // loaded and running as this process", not "what path was I invoked with".
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

    // Runs once, automatically, before main() -- ordering relative to other static
    // initializers in other translation units is unspecified, but all of them
    // (across the whole binary) complete before main() begins, which is what
    // actually matters here: this just needs to run before ROOT/Cling initializes,
    // and that happens inside KTKatydidApp's constructor, inside main().
    struct RootIncludePathInitializer
    {
        RootIncludePathInitializer() { SetRootIncludePathForCicadaAutoloading(); }
    };
    RootIncludePathInitializer gRootIncludePathInitializer;
}
