# WireGuard VPN Auto scripts

Automatic WireGuard VPN server selection and monitoring for NetworkManager. Uses a scoring engine with latency, packet loss, and handshake age to pick the best server from imported WireGuard profiles, then continuously monitors and switches if a significantly better option is found.

## How it works

1. A **dummy WireGuard connection** (`wg-auto` interface) acts as a trigger.
2. When activated, the **NetworkManager dispatcher** starts the `wg-vpn-auto` systemd service.
3. The service runs `wg-vpn-auto.sh --daemon`, which performs an **initial server selection** (pings all candidates, scores them, connects to the best one) and then enters a **monitor loop** that periodically re-evaluates and switches if a better server is found (respecting cooldown and minimum improvement thresholds).
4. Deactivating the dummy connection stops the service and disconnects the active VPN.

## Files

| File | Description |
|---|---|
| `wg-vpn-auto.py` | Main orchestrator — server evaluation, scoring, selection, and monitoring daemon |
| `dispatcher.sh` | NetworkManager dispatcher script — triggers the service on dummy connection up/down |
| `wg-vpn-auto.service` | systemd unit file for the orchestrator daemon |
| `wg-vpn-auto.conf` | Default configuration (installed to `/etc/wg-vpn-auto.conf`) |
| `auto-profile-install.sh` | Installer — imports WireGuard profiles, creates the dummy connection, deploys all files |
| `proxies/` | Directory for WireGuard `.conf` files to import (gitignored) |

## Installation

Place your WireGuard config files (e.g. exported from a VPN provider) into the `proxies/` directory, then run:

```bash
sudo bash auto-profile-install.sh -d -p -n "My VPN Auto"
```

### Installer flags

| Flag | Description |
|---|---|
| `-n <name>` | Connection name for the dummy trigger profile (required on first install) |
| `-p` | Import WireGuard profiles from `proxies/` into NetworkManager |
| `-d` | Delete existing imported profiles and recreate the dummy connection |
| `-r` | Remove the entire installation (service, dispatcher, profiles, config) |
| `-h` | Show usage help |

Running without flags updates the deployed script, service, dispatcher, and config while keeping existing profiles and the dummy connection intact.

## Configuration

Edit `wg-vpn-auto.conf` before installing, or edit `/etc/wg-vpn-auto.conf` after:

```bash
# Preferred countries in priority order
PREFERRED_COUNTRIES=nl,us

# Blacklisted countries
BLACKLIST=jp

# Monitor interval (seconds)
CHECK_INTERVAL=30

# Require at least this much score improvement before switching
MIN_SCORE_IMPROVEMENT=15

# Minimum seconds between switches
SWITCH_COOLDOWN=180

# Threshold safety caps
MAX_LATENCY_MS=250
MAX_PACKET_LOSS=40

# Score weights
W_LAT=1      # latency weight
W_LOSS=5     # packet loss weight
W_STALE=1    # handshake age weight
```

## Usage

Start VPN auto-selection:

```bash
nmcli connection up "My VPN Auto"
```

Stop and disconnect:

```bash
nmcli connection down "My VPN Auto"
```

Check logs:

```bash
tail -f /tmp/nm-dispatch.log
```

## Requirements

- NetworkManager with WireGuard support
- `wg` (wireguard-tools)
- systemd
- Python 3
