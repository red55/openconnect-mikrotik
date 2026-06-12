FROM alpine:latest

ENV SKIP_INSTALL=1

RUN --mount=type=cache,target=/var/cache/apk/ apk add \
    openconnect iproute2 iptables ca-certificates bind-tools vpnc curl tini

ADD https://letsencrypt.org/certs/gen-y/root-yr-by-x1.pem /usr/local/share/ca-certificates/root-yr-by-x1.crt

RUN update-ca-certificates

COPY run.sh /opt/openconnect/run.sh
RUN chmod +x /opt/openconnect/run.sh

ENTRYPOINT ["/sbin/tini","--","/opt/openconnect/run.sh"]
