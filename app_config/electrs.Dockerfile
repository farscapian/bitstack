# ---- build electrs from source ----
FROM rust:1-trixie AS build
ARG ELECTRS_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends \
      clang llvm-dev libclang-dev cmake build-essential git && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --branch "${ELECTRS_VERSION}" --depth=1 https://github.com/romanz/electrs .
RUN cargo build --locked --release

# ---- runtime ----
FROM debian:trixie-slim
ARG UID=1000
ARG GID=1000
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
      && rm -rf /var/lib/apt/lists/* \
      && groupadd -g "${GID}" electrs \
      && useradd -u "${UID}" -g "${GID}" -m -s /usr/sbin/nologin electrs \
      && mkdir -p /var/lib/electrs && chown "${UID}:${GID}" /var/lib/electrs
COPY --from=build /src/target/release/electrs /usr/local/bin/electrs
USER electrs
EXPOSE 50001
ENTRYPOINT ["electrs"]
