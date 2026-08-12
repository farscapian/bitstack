#!/bin/sh
# tor-entrypoint.sh -- runs as root (see tor.Dockerfile) so it can chown the
# docker-managed HiddenServiceDir volume, which is root-owned by default on
# first mount, before Tor starts. Tor treats a HiddenServiceDir not already
# owned by its configured User as a hard security error and refuses to fix
# it itself (unlike DataDirectory, which it does fix) -- see torrc.
set -e
mkdir -p /var/lib/tor/hidden_service
chown -R debian-tor:debian-tor /var/lib/tor
chmod 700 /var/lib/tor/hidden_service
exec tor -f /etc/tor/torrc
