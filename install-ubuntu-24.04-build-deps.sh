#!/usr/bin/env bash

sudo apt install equivs

cat > katydid-build-deps << 'EOF'
Section: libdevel
Priority: optional
Standards-Version: 3.9.2
Package: katydid-build-deps
Version: 1.0
Architecture: all
Maintainer: Your Name <you@example.com>
Depends: libboost-filesystem-dev, libboost-thread-dev, libboost-date-time-dev, libboost-program-options-dev, libfftw3-dev, libmatio-dev
Description: Build dependencies for katydid-bazel
 Dummy metapackage so the underlying -dev packages can be
 removed as a unit via apt autoremove.
EOF

equivs-build katydid-build-deps
sudo apt install ./katydid-build-deps_1.0_all.deb
