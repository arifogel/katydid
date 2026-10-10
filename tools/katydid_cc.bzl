"""katydid_cc_library and katydid_cc_binary: cc_library and cc_binary with Katydid's compile flags.

ROOT's headers need C++17 or newer, and C++17 is a superset of the C++11 the rest of the code
uses.

The Nymph/Scarab logger floors its verbosity at compile time from NDEBUG and STANDARD: NDEBUG
alone (`-c opt`) suppresses Info and Debug, NDEBUG with STANDARD suppresses only Debug and
Trace. STANDARD has no effect when NDEBUG is undefined.
"""

load("@rules_cc//cc:cc_binary.bzl", "cc_binary")
load("@rules_cc//cc:cc_library.bzl", "cc_library")

_COPTS = ["-DSTANDARD"]
_CXXOPTS = ["-std=c++17"]

def _with_katydid_flags(kwargs):
    kwargs["copts"] = _COPTS + kwargs.get("copts", [])
    kwargs["cxxopts"] = _CXXOPTS + kwargs.get("cxxopts", [])
    return kwargs

def katydid_cc_library(**kwargs):
    """A cc_library compiled with Katydid's flags.

    Args:
        **kwargs: cc_library's attributes.
    """
    cc_library(**_with_katydid_flags(kwargs))

def katydid_cc_binary(**kwargs):
    """A cc_binary compiled with Katydid's flags.

    Args:
        **kwargs: cc_binary's attributes.
    """
    cc_binary(**_with_katydid_flags(kwargs))
