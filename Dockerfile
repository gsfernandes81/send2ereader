# Debian slim rather than Alpine: PyMuPDF (needed by pdfCropMargins) publishes prebuilt
# glibc wheels for amd64 and arm64, but none for musl, so on Alpine it compiles MuPDF from
# source, which is slow and memory-hungry on a small server.
#
# Pinned by digest (the multi-arch index) so CI's registry layer cache stays valid: a
# floating tag would move under it every few weeks and turn a small change into a full
# pull on the server. Moving the digest is the deliberate way to get a newer Node and
# fresh Debian packages. To find the current one:
#   docker buildx imagetools inspect node:24-bookworm-slim
FROM docker.io/library/node:24-bookworm-slim@sha256:55fb5f5a527ea2c5c4a95f963e48ef90aa38c7b346054fdc8ee9957a2b55d205

# Create app directory
WORKDIR /usr/src/app

# curl is only used for the downloads below
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl python3 python3-venv && \
    rm -rf /var/lib/apt/lists/*

# Install pdfCropMargins from prebuilt wheels only, so a missing wheel fails the build
# instead of compiling MuPDF. PyMuPDF 2 adds onnxruntime, numpy and other packages for
# features pdfCropMargins does not use, so stay on 1.x.
RUN python3 -m venv /opt/pdfcropmargins && \
    /opt/pdfcropmargins/bin/pip install --no-cache-dir --only-binary=:all: pdfCropMargins "PyMuPDF<2" && \
    ln -s /opt/pdfcropmargins/bin/pdfcropmargins /usr/local/bin/pdfcropmargins

# Download and install kepubify for the image's architecture
RUN set -eu; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) asset=kepubify-linux-64bit; sum=37d7628d26c5c906f607f24b36f781f306075e7073a6fe7820a751bb60431fc5 ;; \
      arm64) asset=kepubify-linux-arm64; sum=5a15b8f6f6a96216c69330601bca29638cfee50f7bf48712795cff88ae2d03a3 ;; \
      *) echo "kepubify: unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/kepubify "https://github.com/pgaskin/kepubify/releases/download/v4.0.4/$asset"; \
    echo "$sum  /usr/local/bin/kepubify" | sha256sum -c; \
    chmod +x /usr/local/bin/kepubify

# Download and install kindlegen. It only exists as a 32-bit x86 binary, so it is left
# out on other architectures (e.g. arm64): the app detects that and disables the
# KindleGen option on the upload page.
RUN set -eu; \
    if [ "$(dpkg --print-architecture)" = amd64 ]; then \
      curl -fsSL -o /tmp/kindlegen.tar.gz https://github.com/zzet/fp-docker/raw/f2b41fb0af6bb903afd0e429d5487acc62cb9df8/kindlegen_linux_2.6_i386_v2_9.tar.gz; \
      echo "9828db5a2c8970d487ada2caa91a3b6403210d5d183a7e3849b1b206ff042296  /tmp/kindlegen.tar.gz" | sha256sum -c; \
      mkdir /tmp/kindlegen; \
      tar xf /tmp/kindlegen.tar.gz --directory /tmp/kindlegen; \
      install -m 755 /tmp/kindlegen/kindlegen /usr/local/bin/kindlegen; \
      rm -rf /tmp/kindlegen /tmp/kindlegen.tar.gz; \
    else \
      echo "kindlegen: no build for $(dpkg --print-architecture), skipping"; \
    fi

# Copy files needed by npm install (patches/ is used by the patch-package postinstall)
COPY package*.json ./
COPY patches ./patches

# Install app dependencies
RUN npm install --omit=dev

# Copy the rest of the app files (see .dockerignore)
COPY . ./

# Create uploads directory if it doesn't exist
RUN mkdir -p uploads

EXPOSE 3001
CMD [ "npm", "start" ]
