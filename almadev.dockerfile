FROM almalinux:9
RUN dnf install -y \
            cpio \
            gcc-c++ \
            git \
            wget \
            tar
# SSH setup
RUN mkdir -p /root/.ssh && \
    ssh-keyscan github.com >> /root/.ssh/known_hosts && \
    ssh-keyscan gitlab.com >> /root/.ssh/known_hosts

# Install bazelisk
RUN wget -q -O /usr/local/bin/bazel https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-amd64 \
&&  chmod +x /usr/local/bin/bazel
RUN echo 'build --disk_cache=/root/.cache/bazel/disk_cache' > /root/.bazelrc
RUN echo 'build --keep_going' >> /root/.bazelrc

RUN mkdir /work
WORKDIR /work

RUN git clone https://github.com/arifogel/katydid
WORKDIR /work/katydid
RUN git checkout claude-alma-rpm

