#!/bin/sh

# Check environment variables
if [ -z "$CA_CN" ]; then
	CA_CN="VPN CA"
fi
if [ -z "$CA_ORG" ]; then
	CA_ORG="Big Corp"
fi
if [ -z "$CA_DAYS" ]; then
	CA_DAYS=9999
fi
if [ -z "$SRV_CN" ]; then
	SRV_CN="www.example.com"
fi
if [ -z "$SRV_ORG" ]; then
	SRV_ORG="MyCompany"
fi
if [ -z "$SRV_DAYS" ]; then
	SRV_DAYS=9999
fi
if [ -z "$ROUTE_PLAN" ]; then
	ROUTE_PLAN="1"
fi

if [ ! -z "$TCP_PORT" ]; then
	sed -i 's/^tcp-port = 443/tcp-port = '$TCP_PORT'/' /docker/config/ocserv.conf
fi
if [ ! -z "$UDP_PORT" ]; then
	sed -i 's/^udp-port = 443/udp-port = '$UDP_PORT'/' /docker/config/ocserv.conf
fi

if [ ! -z "$DNS" ]; then
        sed -i 's/^dns = 8.8.8.8/dns = '$DNS'/' /docker/config/ocserv.conf
fi

if [ ! -z "$DEFAULT_DOMAIN"]; then
	sed -i 's/#default-domain = example.com/default-domain = '$DEFAULT_DOMAIN'/' /docker/config/ocserv.conf
fi 

#Check config files
if [ ! -f /etc/ocserv/ocserv.conf ]; then
	rm -rf /etc/ocserv/ocserv.conf
	cp /docker/config/ocserv.conf /etc/ocserv/ocserv.conf
	if [ $ROUTE_PLAN == "1" ]; then
		cat /docker/cn-no-route.txt >> /etc/ocserv/ocserv.conf
	elif [ $ROUTE_PLAN == "2" ]; then
		cat /docker/all-route.txt >> /etc/ocserv/ocserv.conf
	else
		cat /docker/my-route-$ROUTE_PLAN.txt >> /etc/ocserv/ocserv.conf
	fi
fi

if [ ! -f /etc/ocserv/certs/ca.pem ]; then
	# No ca certification found, generate one
	mkdir /etc/ocserv/certs
	cd /etc/ocserv/certs
	certtool --generate-privkey --outfile ca-key.pem
	cat > ca.tmpl <<-EOCA
	cn = "$CA_CN"
	organization = "$CA_ORG"
	serial = 1
	expiration_days = $CA_DAYS
	ca
	signing_key
	cert_signing_key
	crl_signing_key
	EOCA
	certtool --generate-self-signed --load-privkey ca-key.pem --template ca.tmpl --outfile ca.pem
fi

if [ ! -f /etc/ocserv/certs/server-key.pem ] || [ ! -f /etc/ocserv/certs/server-cert.pem ]; then
	# No server certification found, generate one
	mkdir /etc/ocserv/certs
	cd /etc/ocserv/certs
	certtool --generate-privkey --outfile server-key.pem 
	cat > server.tmpl <<-EOSRV
	cn = "$SRV_CN"
	organization = "$SRV_ORG"
	expiration_days = $SRV_DAYS
	signing_key
	encryption_key
	tls_www_server
	EOSRV
	certtool --generate-certificate --load-privkey server-key.pem --load-ca-certificate ca.pem --load-ca-privkey ca-key.pem --template server.tmpl --outfile server-cert.pem
fi

if [ ! -f /etc/ocserv/certs/crl.pem ]; then
	cat > crl.tmpl <<-EOCRL
	crl_next_update = 365
	crl_number = 1
	EOCRL
	certtool --generate-crl --load-ca-privkey ca-key.pem --load-ca-certificate ca.pem --template crl.tmpl --outfile crl.pem
fi

# Open ipv4 ip forward
sysctl -w net.ipv4.ip_forward=1

# Enable NAT forwarding
iptables -t nat -A POSTROUTING -j MASQUERADE
iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# Enable TUN device
mkdir -p /dev/net
mknod /dev/net/tun c 10 200
chmod 600 /dev/net/tun

# Run OpennConnect Server
exec "$@"
