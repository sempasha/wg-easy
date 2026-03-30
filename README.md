1. Replace ${HOSTNAME} with your hostname;
2. Replace ${EMAIL} with your email address.

do

```sh
touch traefik/acme.json
chmod 0600 traefik/acme.json
docker compose up -d
```