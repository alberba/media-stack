# Tor as a SOCKS5 proxy on port 9150, for the "extras" Profile.
# Built locally by `docker compose build`; Renovate bumps the Alpine base.
FROM alpine:3.24

RUN apk add --no-cache curl tor \
  && printf 'SocksPort 0.0.0.0:9150\nSocksPolicy accept *\nDataDirectory /var/lib/tor\nLog notice stdout\n' > /etc/tor/torrc

USER tor
EXPOSE 9150

ENTRYPOINT ["tor", "-f", "/etc/tor/torrc"]
