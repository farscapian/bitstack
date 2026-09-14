# ---- verify + extract ----
FROM debian:trixie-slim AS build
ARG BITCOIN_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates gnupg wget git && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp/btc
RUN set -eux; \
    base="https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}"; \
    tarball="bitcoin-${BITCOIN_VERSION}-x86_64-linux-gnu.tar.gz"; \
    wget -q "${base}/${tarball}" "${base}/SHA256SUMS" "${base}/SHA256SUMS.asc"; \
    # import Bitcoin Core builder keys and verify the signed checksum file
    git clone --depth=1 https://github.com/bitcoin-core/guix.sigs; \
    gpg --import guix.sigs/builder-keys/*.gpg; \
    gpg --verify SHA256SUMS.asc SHA256SUMS; \
    # verify the tarball against the now-trusted checksums
    grep " ${tarball}\$" SHA256SUMS | sha256sum -c -; \
    tar -xzf "${tarball}"; \
    mkdir -p /opt/bitcoin; \
    cp "bitcoin-${BITCOIN_VERSION}/bin/bitcoind" "bitcoin-${BITCOIN_VERSION}/bin/bitcoin-cli" /opt/bitcoin/

# ---- runtime ----
FROM debian:trixie-slim
ARG UID=1000
ARG GID=1000
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
      && rm -rf /var/lib/apt/lists/* \
      && groupadd -g "${GID}" bitcoin \
      && useradd -u "${UID}" -g "${GID}" -m -s /usr/sbin/nologin bitcoin
COPY --from=build /opt/bitcoin/bitcoind /opt/bitcoin/bitcoin-cli /usr/local/bin/
USER bitcoin
EXPOSE 8332 8333
ENTRYPOINT ["bitcoind"]
