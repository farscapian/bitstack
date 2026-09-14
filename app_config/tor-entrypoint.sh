#!/bin/sh
# tor-entrypoint.sh -- runs as root (see tor.Dockerfile) so it can chown the
# bind-mounted HiddenServiceDir (~/.bitstack/onion on the host, owned by
# whatever the host side has at the time) to debian-tor before Tor starts.
# Tor treats a HiddenServiceDir not already owned by its configured User as
# a hard security error and refuses to fix it itself (unlike DataDirectory,
# which it does fix) -- see torrc. Run on every start, not just first mount,
# since it's cheap and this is the only thing that keeps it correct.
set -e
mkdir -p /var/lib/tor/hidden_service
chown -R debian-tor:debian-tor /var/lib/tor
chmod 700 /var/lib/tor/hidden_service
exec tor -f /etc/tor/torrc
