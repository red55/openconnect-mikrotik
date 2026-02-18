FROM alpine:latest

RUN apk add --no-cache \
    openconnect iproute2 iptables ca-certificates bind-tools vpnc tini \
 && update-ca-certificates

COPY run.sh /opt/openconnect/run.sh
RUN chmod +x /opt/openconnect/run.sh

ENTRYPOINT ["/sbin/tini","--","/opt/openconnect/run.sh"]
