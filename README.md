# 🔐 wg-easy deployment

This repository contains a Docker Compose deployment of [wg-easy](https://github.com/wg-easy/wg-easy) behind Traefik.

The intended installation method is the provider's web console on a fresh Ubuntu server. The installer currently supports Ubuntu 22.04 and 24.04 LTS.

## 🚀 Automated installation

Open the new server's web console and run as `root`:

```sh
curl -fsSL https://raw.githubusercontent.com/sempasha/wg-easy/master/install.sh -o install.sh
less install.sh
bash install.sh
```

The installer asks before every mutating phase. Answer exactly `y` or `n`; any other answer is treated as `n`.

The optional phases are:

1. 📦 Install OpenSSH, Docker Compose, and UFW.
2. 👤 Ask for a Linux username and a public SSH key.
3. 🔑 Create the user, add it to `sudo` and Docker access, and install the key.
4. ✅ Wait for you to verify SSH login from another terminal.
5. 🛡️ After confirmation, disable root SSH login and SSH password authentication.
6. 🌐 Ask for the domain name and the Let's Encrypt email address.
7. 🔥 Configure the firewall using the ports published by the Compose file.
8. 🔄 Connect to the old server and migrate the data used by the current Compose configuration.
9. 🩺 Start the new services and check DNS, HTTP, and HTTPS connectivity.

Do not confirm the SSH-hardening question until key-based login works in a separate terminal. If the check is not confirmed, password SSH remains enabled so that the current console session is not locked out. Skipping a phase leaves the corresponding system configuration unchanged.

## 🔄 Migration from an old server

The installer asks for the old server hostname or IP address, SSH port, and username. The username defaults to the new administrator's username to reduce typing, but it can be changed.

Three authentication methods are supported:

1. **Temporary public key** — the installer generates a temporary key and displays its public part. Add it to the old server using SSH, the old provider's web console, or another available method.
2. **Private key** — paste the existing private key into the web console and finish with a line containing `END_PRIVATE_KEY`. This is an emergency mode: the key may be visible to the hosting provider's console logging. It is stored only temporarily and removed when the installer exits.
3. **Password** — enter the old server's SSH password when prompted. It is not written to a configuration file.

The old SSH user must be able to run Docker directly or via passwordless `sudo -n`. A password prompt for remote `sudo` is intentionally not supported.

The installer reads the volumes required by the current Compose file from the GitHub repository. It looks for matching mounts on the old server and migrates all matching named volumes. It also migrates `traefik/acme.json` when the file exists, preserving the existing Let's Encrypt account and certificates.

If the old deployment uses an older Compose configuration, some volumes may be missing. The installer reports those volumes and continues with the ones it can find.

For a consistent copy, containers using the data are stopped temporarily. No container is removed and no source data is deleted. After migration, each old container is returned to its original state: running containers are started again, and stopped containers remain stopped.

If a destination volume already contains data, the installer offers to:

- overwrite it after creating a backup under `/var/backups/wg-easy`;
- keep it and skip that volume; or
- abort the migration.

## 🌐 DNS and network requirements

Configure the DNS record separately with your DNS provider. Before or during installation, point the domain to the new server's public IP address.

The installer asks whether to change the SSH port, configures `sshd` only after confirmation, and opens the selected port in UFW. The previous SSH port remains available as a fallback.

The following additional ports are required by the current Compose file:

- SSH: the port you specify during installation;
- TCP/UDP 80;
- TCP/UDP 443;
- UDP 51820 for WireGuard.

Let's Encrypt HTTP validation requires that the domain resolve to the new server and that port 80 be reachable from the Internet.

## 🌍 IPv6 support

The installer enables IPv6 in the Linux kernel, configures UFW to handle IPv6, and ensures that Docker has `ipv6` and `ip6tables` enabled without overwriting other Docker settings. It checks the host's IPv6 address, default route, and outbound IPv6 connectivity.

The Compose file uses the private Docker subnet `fdcc:ad94:bacf:61a3::/64`. This provides IPv6 inside the Docker network but does not provide public IPv6 connectivity by itself. Public IPv6 requires an IPv6 address and route from the hosting provider.

## ⚙️ Environment configuration

The installer creates `/opt/wg-easy/.env`:

```dotenv
COMPOSE_PROJECT_NAME=wg-easy
DOMAIN_NAME=wireguard.example.com
ACME_EMAIL=admin@example.com
```

Compose substitutes `DOMAIN_NAME` and `ACME_EMAIL` on the host before starting the containers. `ACME_EMAIL` does not need to be defined in the Traefik container's `environment` section.

The `.env` file and `traefik/acme.json` are ignored by Git and must not be committed to this public repository.

## 🛠️ Manual deployment

If you do not use the installer:

```sh
printf 'COMPOSE_PROJECT_NAME=wg-easy\nDOMAIN_NAME=wireguard.example.com\nACME_EMAIL=admin@example.com\n' > .env
touch traefik/acme.json
chmod 0600 traefik/acme.json
docker compose config
docker compose up -d
```

`docker compose config` should show the rendered domain and email. It will fail if `DOMAIN_NAME` or `ACME_EMAIL` is missing.
