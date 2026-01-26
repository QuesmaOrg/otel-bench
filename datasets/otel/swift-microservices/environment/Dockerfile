FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install basic dependencies
RUN apt-get update && apt-get install -y \
    g++ \
    make \
    cmake \
    curl \
    wget \
    python3 \
    python3-pip \
    uuid-dev \
    less \
    binutils \
    git \
    gnupg2 \
    libc6-dev \
    libcurl4-openssl-dev \
    libedit2 \
    libgcc-11-dev \
    libpython3-dev \
    libsqlite3-0 \
    libstdc++-11-dev \
    libxml2-dev \
    libz3-dev \
    pkg-config \
    unzip \
    zlib1g-dev \
    tmux \
    asciinema \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install Swift via Swiftly (official installer)
ENV SWIFTLY_HOME_DIR="/root/.local/share/swiftly"
ENV SWIFTLY_BIN_DIR="/root/.local/bin"
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "arm64" ]; then SWIFTARCH="aarch64"; else SWIFTARCH="x86_64"; fi && \
    curl -O https://download.swift.org/swiftly/linux/swiftly-${SWIFTARCH}.tar.gz && \
    tar zxf swiftly-${SWIFTARCH}.tar.gz && \
    ./swiftly init -y && \
    rm -f swiftly-*.tar.gz swiftly
ENV PATH="/root/.local/bin:$PATH"


# Install uv for running pytest
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

# Install otelite from GitHub releases
RUN ARCH=$(dpkg --print-architecture) && \
    wget -O /usr/local/bin/otelite https://github.com/QuesmaOrg/otelite/releases/download/v0.1.0/otelite-linux-${ARCH} && \
    chmod +x /usr/local/bin/otelite

COPY code /workdir

WORKDIR /workdir
