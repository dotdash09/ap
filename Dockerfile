FROM alpine

LABEL Kim Eungtae <dotdash09@gmail.com>

RUN apk add --no-cache bash hostapd iptables dhcp docker iproute2 iw
RUN echo "" > /var/lib/dhcp/dhcpd.leases
ADD ap-start.sh /bin/ap-start.sh

ENTRYPOINT [ "/bin/ap-start.sh" ]
