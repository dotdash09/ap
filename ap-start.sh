#!/bin/bash -e

# Check if running in privileged mode
if [ ! -w "/sys" ] ; then
    echo "[Error] Not running in privileged mode."
    exit 1
fi

# Default values
true ${INT_INTERFACE:=enp1s0}
true ${WIRED_INTERFACE:=enx705dccfecf80}
true ${WIRED_SUBNET:=192.168.84.0}
true ${WIRED_AP_ADDR:=192.168.84.1}
true ${WIRELESS_INTERFACE:=wlo1}
true ${WIRELESS_SUBNET:=192.168.85.0}
true ${WIRELESS_AP_ADDR:=192.168.85.1}
true ${SSID:=docker-ap}
true ${CHANNEL:=11}
true ${WPA_PASSPHRASE:=qqwe1123}
true ${HW_MODE:=g}
true ${DRIVER:=nl80211}
true ${HT_CAPAB:=[HT40-][SHORT-GI-20][SHORT-GI-40]}
true ${MODE:=host}
true ${DNS1:=219.250.36.130}
true ${DNS2:=210.220.163.82}


# Attach interface to container in guest mode
if [ "$MODE" == "guest"  ]; then
    echo "Attaching interface to container"

    CONTAINER_ID=$(cat /proc/self/cgroup | grep -o  -e "/docker/.*" | head -n 1| sed "s/\/docker\/\(.*\)/\\1/")
    CONTAINER_PID=$(docker inspect -f '{{.State.Pid}}' ${CONTAINER_ID})
    CONTAINER_IMAGE=$(docker inspect -f '{{.Config.Image}}' ${CONTAINER_ID})

    docker run -t --privileged --net=host --pid=host --rm --entrypoint /bin/sh ${CONTAINER_IMAGE} -c "
        PHY=\$(echo phy\$(iw dev ${WIRELESS_INTERFACE} info | grep wiphy | tr ' ' '\n' | tail -n 1))
        iw phy \$PHY set netns ${CONTAINER_PID}
    "

    ip link set ${WIRELESS_INTERFACE} name wlan0

    INTERFACE=wlan0
fi

if [ ! -f "/etc/hostapd.conf" ] ; then
    cat > "/etc/hostapd.conf" <<EOF
interface=${WIRELESS_INTERFACE}
driver=${DRIVER}
ssid=${SSID}
hw_mode=${HW_MODE}
channel=${CHANNEL}
wpa=2
wpa_passphrase=${WPA_PASSPHRASE}
wpa_key_mgmt=WPA-PSK
# TKIP is no secure anymore
#wpa_pairwise=TKIP CCMP
wpa_pairwise=CCMP
rsn_pairwise=CCMP
wpa_ptk_rekey=600
ieee80211n=1
ht_capab=${HT_CAPAB}
wmm_enabled=1 
EOF

fi

# unblock wlan
rfkill unblock wlan

echo "Setting interface ${WIRELESS_INTERFACE}"

# Setup interface and restart DHCP service 
ip link set ${WIRELESS_INTERFACE} up
ip addr flush dev ${WIRELESS_INTERFACE}
ip addr add ${WIRELESS_AP_ADDR}/24 dev ${WIRELESS_INTERFACE}

# wired
ip link set ${WIRED_INTERFACE} up
ip addr flush dev ${WIRED_INTERFACE}
ip addr add ${WIRED_AP_ADDR}/24 dev ${WIRED_INTERFACE}

# NAT settings
echo "NAT settings ip_dynaddr, ip_forward"

for i in ip_dynaddr ip_forward ; do 
  if [ $(cat /proc/sys/net/ipv4/$i) ]; then
    echo $i already 1 
  else
    echo "1" > /proc/sys/net/ipv4/$i
  fi
done

cat /proc/sys/net/ipv4/ip_dynaddr 
cat /proc/sys/net/ipv4/ip_forward

echo "Setting iptables for outgoing traffics on ${INT_INTERFACE}..."

# wireless setting
iptables -t nat -D POSTROUTING -s ${WIRELESS_SUBNET}/24 -o ${INT_INTERFACE} -j MASQUERADE > /dev/null 2>&1 || true
iptables -t nat -A POSTROUTING -s ${WIRELESS_SUBNET}/24 -o ${INT_INTERFACE} -j MASQUERADE

iptables -D FORWARD -i ${INT_INTERFACE} -o ${WIRELESS_INTERFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT > /dev/null 2>&1 || true
iptables -A FORWARD -i ${INT_INTERFACE} -o ${WIRELESS_INTERFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT

iptables -D FORWARD -i ${WIRELESS_INTERFACE} -o ${INT_INTERFACE} -j ACCEPT > /dev/null 2>&1 || true
iptables -A FORWARD -i ${WIRELESS_INTERFACE} -o ${INT_INTERFACE} -j ACCEPT

# wired setting
iptables -t nat -A POSTROUTING -o ${INT_INTERFACE} -j MASQUERADE
iptables -A FORWARD -i ${INT_INTERFACE} -o ${WIRED_INTERFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i ${WIRED_INTERFACE} -o ${INT_INTERFACE} -j ACCEPT

echo "Configuring DHCP server .."

cat > "/etc/dhcp/dhcpd.conf" <<EOF
#wired
subnet ${WIRED_SUBNET} netmask 255.255.255.0 {
  range 192.168.84.100 192.168.84.200;
  option routers ${WIRED_AP_ADDR};
  option domain-name-servers ${DNS1}, ${DNS2};
  option subnet-mask 255.255.255.0;
}

#wireless
subnet ${WIRELESS_SUBNET} netmask 255.255.255.0 {
  range 192.168.85.100 192.168.85.200;
  option routers ${WIRELESS_AP_ADDR};
  option domain-name-servers ${DNS1}, ${DNS2};
  option subnet-mask 255.255.255.0;
}
EOF

echo "Starting DHCP server .."

dhcpd ${WIRED_INTERFACE} ${WIRELESS_INTERFACE}

echo "Starting HostAP daemon ..."
/usr/sbin/hostapd /etc/hostapd.conf 

