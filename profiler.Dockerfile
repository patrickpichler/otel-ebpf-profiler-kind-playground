FROM --platform=$BUILDPLATFORM debian:testing AS builder-env

# cross_debian_arch: amd64 or arm64
# cross_pkg_arch: x86-64 or aarch64
RUN cross_debian_arch=$(uname -m | sed -e 's/aarch64/amd64/'  -e 's/x86_64/arm64/'); \
    cross_pkg_arch=$(uname -m | sed -e 's/aarch64/x86-64/' -e 's/x86_64/aarch64/'); \
    apt-get update -y && \
    apt-get dist-upgrade -y && \
    apt-get install -y wget make git clang-17 unzip libc6-dev g++ gcc pkgconf \
        gcc-${cross_pkg_arch}-linux-gnu libc6-${cross_debian_arch}-cross && \
    apt-get clean autoclean && \
    apt-get autoremove --yes

COPY opentelemetry-ebpf-profiler/go.mod /tmp/go.mod
# Extract Go version from go.mod
RUN GO_VERSION=$(grep -oPm1 '^go \K([[:digit:].]+)' /tmp/go.mod) && \
    GOARCH=$(uname -m) && if [ "$GOARCH" = "x86_64" ]; then GOARCH=amd64; elif [ "$GOARCH" = "aarch64" ]; then GOARCH=arm64; fi && \
    wget -qO- https://golang.org/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz | tar -C /usr/local -xz

ENV PATH="/usr/local/go/bin:$PATH"

# To avoid permission issues, when running as non root
ENV GOCACHE=/tmp/gocache/cache
ENV GOMODCACHE=/tmp/gocache/gomodcache
ENV GOPATH=/tmp/gocache/gopath
RUN mkdir -m 777 /agent

WORKDIR /agent

# gRPC dependencies
RUN --mount=type=cache,target=/tmp/gocache go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.31.0
RUN --mount=type=cache,target=/tmp/gocache go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.3.0

RUN                                                                                \
  PB_URL="https://github.com/protocolbuffers/protobuf/releases/download/v24.4/";   \
  PB_FILE="protoc-24.4-linux-x86_64.zip";                                      \
  INSTALL_DIR="/usr/local";                                                        \
                                                                                   \
  wget -q "$PB_URL/$PB_FILE"                                                       \
    && unzip "$PB_FILE" -d "$INSTALL_DIR" 'bin/*' 'include/*'                      \
    && chmod +xr "$INSTALL_DIR/bin/protoc"                                         \
    && find "$INSTALL_DIR/include" -type d -exec chmod +x {} \;                    \
    && find "$INSTALL_DIR/include" -type f -exec chmod +r {} \;                    \
    && rm "$PB_FILE"

# Append to /etc/profile for login shells
RUN echo 'export PATH="/usr/local/go/bin:$PATH"' >> /etc/profile

ENTRYPOINT ["/bin/bash", "-l", "-c"]

FROM --platform=$BUILDPLATFORM builder-env AS builder

# Provided by docker build
ARG TARGETOS
ARG TARGETARCH

ARG VERSION

# To avoid permission issues, when running as non root
ENV GOCACHE=/tmp/gocache/cache
ENV GOMODCACHE=/tmp/gocache/gomodcache
ENV GOPATH=/tmp/gocache/gopath

WORKDIR /agent
COPY opentelemetry-ebpf-profiler /agent

RUN --mount=type=cache,target=/tmp/gocache make -C support/ebpf errors.h

RUN --mount=type=cache,target=/tmp/gocache GOOS=${TARGETOS} GOARCH=${TARGETARCH} make \
  TARGET_ARCH=${TARGETARCH}\
  VERSION=${VERSION}

FROM alpine:latest

COPY --from=builder /agent/ebpf-profiler /usr/bin/local/ebpf-profiler

ENTRYPOINT ["/usr/bin/local/ebpf-profiler"]
