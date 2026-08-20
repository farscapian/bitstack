# ---- tor hidden service publishing electrs' Electrum RPC endpoint ----
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends tor \
      && rm -rf /var/lib/apt/lists/*
COPY torrc /etc/tor/torrc
COPY tor-entrypoint.sh /usr/local/bin/tor-entrypoint.sh
RUN chmod +x /usr/local/bin/tor-entrypoint.sh
# No USER here: started as root so tor-entrypoint.sh can chown the
# bind-mounted HiddenServiceDir (~/.bitstack/onion on the host) to
# debian-tor -- Tor itself refuses to fix that ownership and hard-fails
# instead (unlike DataDirectory, which it does fix) -- before Tor drops to
# debian-tor via the 'User' directive in torrc.
ENTRYPOINT ["/usr/local/bin/tor-entrypoint.sh"]
