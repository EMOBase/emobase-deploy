#!/bin/bash
# add_apache_site.sh
#
# Sets up an Apache reverse-proxy vhost for a local service and secures it
# with a Let's Encrypt TLS certificate.
#
# What it does:
#   1. Writes an Apache virtual host config for ${DOMAIN} that terminates
#      SSL and reverse-proxies all traffic to a local backend on ${PORT}
#      (e.g. http://localhost:9094).
#   2. Briefly stops Apache so certbot can bind port 443 in standalone
#      mode to obtain a Let's Encrypt certificate for ${DOMAIN}.
#   3. Restarts Apache, enables the new site, validates the config, and
#      reloads Apache to apply it.
#
# Requirements:
#   - Run as root (needs systemctl, a2ensite, certbot).
#   - DNS for ${DOMAIN} must already point at this host, and port 443
#     must be reachable from the internet
#
# Usage:
#   sudo ./add_apache_site.sh
#   (edit DOMAIN and PORT variables below before running)


set -eo pipefail

SPECIES="tdom"
DOMAIN="${SPECIES}.emobase.uni-goettingen.de"
PORT="9096"
CONF="/etc/apache2/sites-available/${SPECIES}.conf"

echo "Creating Apache configuration..."

cat > "$CONF" <<EOF
<VirtualHost *:443>
    ServerName ${DOMAIN}

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/${DOMAIN}/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/${DOMAIN}/privkey.pem

    ProxyPreserveHost On
    RequestHeader set X-Forwarded-Proto "expr=%{REQUEST_SCHEME}"

    ProxyPass / http://localhost:${PORT}/
    ProxyPassReverse / http://localhost:${PORT}/

    ErrorLog \${APACHE_LOG_DIR}/${SPECIES}_error.log
    CustomLog \${APACHE_LOG_DIR}/${SPECIES}_access.log combined
</VirtualHost>
EOF

echo "Stopping Apache..."
systemctl stop apache2

echo "Obtaining Let's Encrypt certificate..."
certbot certonly --standalone -d "$DOMAIN"

echo "Starting Apache..."
systemctl start apache2

echo "Enabling site..."
a2ensite ${SPECIES}.conf

echo "Testing Apache configuration..."
apache2ctl configtest

echo "Reloading Apache..."
systemctl reload apache2

echo
echo "Done!"
echo "https://${DOMAIN} -> http://localhost:${PORT}"
