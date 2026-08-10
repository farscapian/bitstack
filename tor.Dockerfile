# ---- tor hidden service publishing electrs' Electrum RPC endpoint ----
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends tor \
      && rm -rf /var/lib/apt/lists/*
COPY torrc /etc/tor/torrc
# No USER here: started as root so it can fix perms on the (docker-managed,
# root-owned-by-default) HiddenServiceDir volume, then drops to debian-tor
# itself via the 'User' directive in torrc.
ENTRYPOINT ["tor", "-f", "/etc/tor/torrc"]
