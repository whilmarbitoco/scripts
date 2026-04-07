#!/bin/bash
# Renew Let’s Encrypt certs and reload services

domains=("example.com" "www.example.com")

for d in "${domains[@]}"; do
  certbot renew --cert-name $d
done

# Reload NGINX/Docker services
systemctl reload nginx
docker restart myapp
