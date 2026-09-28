#!/usr/bin/env bash
# Downloads a pinned .rpm from a permalinked archive (AlmaLinux's vault.almalinux.org, or
# EPEL's dl.fedoraproject.org/pub/archive/epel/) and prints its sha256, formatted as a
# ready-to-paste entry for the download table in tools/almalinux_libs.bzl.
#
# Run this from a machine that can actually reach the archive (this sandbox's network
# allowlist blocks both vault.almalinux.org and dl.fedoraproject.org) - a plain laptop/CI
# runner with normal internet access is fine, an AlmaLinux container is not required just for
# this step.
#
# Usage:
#   tools/pin_rpm.sh <pkg-key> <url>
#
# Example (the two matio packages tools/almalinux_libs.bzl currently has as placeholders):
#   tools/pin_rpm.sh matio-devel \
#     https://dl.fedoraproject.org/pub/archive/epel/9.7/Everything/x86_64/Packages/m/matio-devel-1.5.27-1.el9.x86_64.rpm
#   tools/pin_rpm.sh matio \
#     https://dl.fedoraproject.org/pub/archive/epel/9.7/Everything/x86_64/Packages/m/matio-1.5.27-1.el9.x86_64.rpm
#
# dl.fedoraproject.org/pub/archive/epel/ is NOT indexed by a bare major version ("9") the way
# vault.almalinux.org is indexed by AlmaLinux's own release numbers - it's dated/point
# snapshots (9.0, 9.1, 9.2, ...), and not every snapshot has every package. If a URL 404s,
# use tools/find_epel_snapshot.sh to find which snapshot(s) actually have the file before
# retrying this script - don't substitute the live (non-archived) mirror just to get a sha256,
# since that mirror is exactly the rolling, prunable source this pinning exists to avoid.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <pkg-key> <url>" >&2
  exit 1
fi

pkg_key="$1"
url="$2"
filename="$(basename "$url")"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

echo "Downloading $url ..." >&2
curl -fSL -o "$tmp_dir/$filename" "$url"

sha256="$(sha256sum "$tmp_dir/$filename" | awk '{print $1}')"

# repo="" is intentionally left for you to fill in from the URL's own path (e.g. "AppStream",
# "BaseOS", or, for an EPEL archive URL, there is no repo subdirectory - see how
# tools/almalinux_libs.bzl's download_and_extract_rpm-equivalent builds each platform's URL).
cat <<EOF

"$pkg_key": {
    "filename": "$filename",
    "sha256": "$sha256",
},
EOF

echo "Paste the block above into tools/almalinux_libs.bzl's download table for '$pkg_key'," >&2
echo "replacing its TODO placeholder - keep whatever 'repo'/URL-shape fields that table" >&2
echo "already expects; this script only computes filename + sha256." >&2
