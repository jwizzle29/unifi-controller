# unifi-controller

UniFi Network Application (controller) running as a Podman quadlet on the
`.159` control-plane VM, sharing the same Linux host as nginx-proxy and the
NetBird control plane.

Used to adopt and manage UniFi APs on the LAN. APs broadcast L2 discovery
to the controller; the controller pushes config to them and shows stats.

## Stack

| Container | Image | Role |
|---|---|---|
| unifi | `linuxserver/unifi-network-application:latest` | Controller (web UI + AP management) |

## Layout

```
.
├── deploy.sh
├── .env.example
├── containers/
│   └── unifi.container
└── README.md
```

On the host after deploy:

```
/srv/unifi/data/                    # MongoDB + controller config
/etc/containers/systemd/unifi.container -> /srv/unifi/unifi.container
```

## Ports

| Host port | Container port | Purpose |
|---|---|---|
| 8443/tcp | 8443/tcp | Web UI (HTTPS) |
| 8080/tcp | 8080/tcp | Device communication (AP inform) |
| 10001/udp | 10001/udp | Device discovery (broadcast) |

**Skipped intentionally:**
- `3478/udp` (STUN) — already used by NetBird on this host. STUN is only
  needed for cloud-managed setups; LAN adoption works without it.
- `8843/tcp`, `8880/tcp` (guest portal redirectors) — not using guest
  portal; can be added later.
- `6789/tcp` (speed test) — optional.

## Prerequisites

- Ubuntu 24 with `podman >= 4.4`.
- AP and controller on the same LAN (10.0.0.0/24 in this homelab) — required
  for L2 discovery without STUN.

## Deploy

```bash
sudo apt install -y podman
git clone <repo> /opt/unifi-controller
cd /opt/unifi-controller
cp .env.example .env
$EDITOR .env       # TZ, PUID, PGID
sudo ./deploy.sh
```

Then from any LAN device: `https://10.0.0.159:8443` → first-run wizard
(local admin, no cloud sign-in needed) → adopt the AP from the
"Pending Adoption" section → set SSID + WPA password.

## Updating

```bash
sudo podman auto-update     # AutoUpdate=registry on the container
```

## AP factory reset (used APs)

If the AP was previously adopted by another controller, factory reset before
trying to adopt it here:

```bash
ssh ubnt@<ap-ip>            # default password: ubnt
syswrapper.sh restore-default
```

AP reboots, comes back at the same DHCP lease, and shows up in
"Pending Adoption".

## Notes

- The controller can be **off** day-to-day after the AP is adopted and
  configured. The AP keeps its config and broadcasts SSID standalone.
  Restart the controller only when changing settings or watching stats.
- This repo doesn't currently expose the controller via nginx-proxy. To
  reach it from outside the LAN, set up a NetBird-mesh access path or
  add a `unifi-controller` site to nginx-proxy.
