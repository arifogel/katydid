#!/usr/bin/env bash
# One-off helper: dl.fedoraproject.org/pub/archive/epel/ is NOT indexed by a bare major
# version like "9" - it's dated/point snapshots (9.0, 9.1, 9.2, ...). This probes each
# candidate snapshot directly (HEAD request) for a given package filename and reports which
# ones actually have it, so you can pick a real, working permalink for tools/almalinux_libs.bzl
# and tools/pin_rpm.sh. Not meant to be kept around - delete once matio/matio-devel are pinned.
set -euo pipefail

filename="${1:?Usage: $0 <rpm-filename> (e.g. matio-devel-1.5.27-1.el9.x86_64.rpm)}"

# Adjust/extend this range if none of these hit - EPEL 9 point snapshots as of writing run
# roughly 9.0 through 9.7+; check https://docs.fedoraproject.org/en-US/epel/ if this list is
# stale.
for v in 9.0 9.1 9.2 9.3 9.4 9.5 9.6 9.7 9.8; do
    url="https://dl.fedoraproject.org/pub/archive/epel/${v}/Everything/x86_64/Packages/m/${filename}"
    status="$(curl -s -o /dev/null -w '%{http_code}' -L "$url")"
    echo "${v}: ${status}  ${url}"
done
