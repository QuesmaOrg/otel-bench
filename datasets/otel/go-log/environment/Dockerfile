FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install C++ compiler and dependencies
RUN apt-get update && apt-get install -y \
    g++ \
    make \
    cmake \
    curl \
    wget \
    python3 \
    python3-pip \
    uuid-dev \
    golang-go \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*



COPY code /workdir

