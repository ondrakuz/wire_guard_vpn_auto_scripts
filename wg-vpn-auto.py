#!/usr/bin/env python3

import asyncio
from datetime import datetime
import subprocess
import re
import time
import pwd
import shlex
from pathlib import Path

# ------------------------------------------------------------
# Configuration defaults (override via config file)
# ------------------------------------------------------------

PREFERRED_COUNTRIES = ["nl", "de"]
BLACKLIST = ["jp"]

CHECK_INTERVAL = 30
MIN_SCORE_IMPROVEMENT = 15
SWITCH_COOLDOWN = 180

W_LAT = 1
W_LOSS = 5
W_STALE = 1

ACTIVE_FILE = Path("/run/wg-vpn-auto.active")
SWITCH_FILE = Path("/run/wg-vpn-auto.lastswitch")

LOG_FILE = Path("/tmp/nm-dispatch.log")

# ------------------------------------------------------------
# Utilities
# ------------------------------------------------------------

def log(msg):
    ts = datetime.now().strftime('%y-%m-%d %H:%M:%S')
    line = f"[{ts}] {msg}"

    print(line)

    if LOG_FILE and LOG_FILE.exists():
        with open(LOG_FILE, "a") as log_file:
            print(line, file=log_file, flush=True)

def detect_nm_storage():
    for p in [
        "/run/NetworkManager/system-connections",
        "/etc/NetworkManager/system-connections",
    ]:
        path = Path(p)
        if path.exists():
            return path
    raise RuntimeError("No NM storage found")

NM_STORAGE = detect_nm_storage()

def list_wireguard_connections():
    result = subprocess.run(
        ["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show"],
        capture_output=True,
        text=True,
    )
    conns = []
    for line in result.stdout.splitlines():
        name, typ = line.split(":")
        if typ == "wireguard":
            conns.append(name)
    return conns

def find_conf_file(name):
    for f in NM_STORAGE.glob("*.nmconnection"):
        if f.read_text().find(f"id={name}") != -1:
            return f
    return None

def extract_endpoint(conf):
    text = conf.read_text()
    m = re.search(r"endpoint\s*=\s*([0-9\.]+):", text)
    return m.group(1) if m else None

# ------------------------------------------------------------
# Load configuration file (Bash-compatible style)
# ------------------------------------------------------------

def detect_active_user():
    try:
        result = subprocess.run(
            ["loginctl", "list-sessions", "--no-legend"],
            capture_output=True,
            text=True,
        )
        line = result.stdout.strip().splitlines()
        if not line:
            return None
        first = line[0].split()
        return first[2] if len(first) >= 3 else None
    except:
        return None

def load_config():
    global PREFERRED_COUNTRIES
    global BLACKLIST
    global CHECK_INTERVAL
    global MIN_SCORE_IMPROVEMENT
    global SWITCH_COOLDOWN
    global W_LAT
    global W_LOSS
    global W_STALE
    global LOG_FILE

    active_user = detect_active_user()

    config_path = None

    if active_user:
        try:
            user_home = pwd.getpwnam(active_user).pw_dir
            user_conf = Path(user_home) / ".config/wg-vpn-auto.conf"
            if user_conf.exists():
                config_path = user_conf
        except KeyError:
            pass

    if not config_path:
        etc_conf = Path("/etc/wg-vpn-auto.conf")
        if etc_conf.exists():
            config_path = etc_conf

    if not config_path:
        return

    log(f"Using config: {config_path}")

    # Very simple Bash-style parser (KEY=value)
    for line in config_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue

        if "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()

        # remove quotes
        value = value.strip('"').strip("'")

        if key == "PREFERRED_COUNTRIES":
            PREFERRED_COUNTRIES = [c.strip() for c in value.split(",")]
        elif key == "BLACKLIST":
            BLACKLIST = [c.strip() for c in value.split(",")]
        elif key == "CHECK_INTERVAL":
            CHECK_INTERVAL = int(value)
        elif key == "MIN_SCORE_IMPROVEMENT":
            MIN_SCORE_IMPROVEMENT = int(value)
        elif key == "SWITCH_COOLDOWN":
            SWITCH_COOLDOWN = int(value)
        elif key == "W_LAT":
            W_LAT = int(value)
        elif key == "W_LOSS":
            W_LOSS = int(value)
        elif key == "W_STALE":
            W_STALE = int(value)
        elif key == "LOG_FILE":
            LOG_FILE = Path(value)

# Load config immediately after defining defaults
load_config()

# ------------------------------------------------------------
# Async Probing
# ------------------------------------------------------------

async def probe_latency(endpoint):
    proc = await asyncio.create_subprocess_exec(
        "ping", "-c", "3", "-W", "1", endpoint,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL
    )
    stdout, _ = await proc.communicate()
    out = stdout.decode()

    loss_match = re.search(r"(\d+)% packet loss", out)
    rtt_match = re.search(r"= [^/]+/([^/]+)/", out)

    loss = int(loss_match.group(1)) if loss_match else 100
    latency = int(float(rtt_match.group(1))) if rtt_match else 9999

    return latency, loss

def handshake_age():
    result = subprocess.run(["wg", "show"], capture_output=True, text=True)
    m = re.search(r"latest handshake: (\d+) seconds ago", result.stdout)
    return int(m.group(1)) if m else 999

def score(lat, loss, hs):
    return lat * W_LAT + loss * W_LOSS + hs * W_STALE

# ------------------------------------------------------------
# Parallel evaluation
# ------------------------------------------------------------

async def evaluate_all(active):
    candidates = []

    for name in list_wireguard_connections():
        if name == active:
            continue

        conf = find_conf_file(name)
        if not conf:
            continue

        endpoint = extract_endpoint(conf)
        if not endpoint:
            continue

        candidates.append((name, endpoint))

    tasks = [
        asyncio.create_task(probe_latency(endpoint))
        for _, endpoint in candidates
    ]

    best = None
    best_score = 10**9

    results = await asyncio.gather(*tasks)

    for (name, _), (lat, loss) in zip(candidates, results):
        hs = handshake_age()
        sc = score(lat, loss, hs)
        log(f"{name}: latency={lat} loss={loss} score={sc}")

        if sc < best_score:
            best_score = sc
            best = name

    return best, best_score

# ------------------------------------------------------------
# Main loop
# ------------------------------------------------------------

async def monitor():
    last_switch = 0

    while True:

        active = 'None'
        current_score = 0
        if ACTIVE_FILE.exists():
            active = ACTIVE_FILE.read_text().strip()

            conf = find_conf_file(active)
            if not conf:
                continue

            endpoint = extract_endpoint(conf)
            if not endpoint:
                continue

            lat, loss = await probe_latency(endpoint)
            hs = handshake_age()
            current_score = score(lat, loss, hs)

        subprocess.run(["nmcli", "connection", "down", active])

        best, best_score = await evaluate_all(active)
        if not best:
            continue

        improvement = current_score - best_score

        if SWITCH_FILE.exists():
            last_switch = int(SWITCH_FILE.read_text())

        now = int(time.time())

        if (
            (improvement > MIN_SCORE_IMPROVEMENT
            and now - last_switch > SWITCH_COOLDOWN)
            or not active
        ):
            log(f"Switching {active} -> {best}")

            subprocess.run(["nmcli", "connection", "up", best])

            ACTIVE_FILE.write_text(best)
            SWITCH_FILE.write_text(str(now))
        else:
            subprocess.run(["nmcli", "connection", "up", active])


        await asyncio.sleep(CHECK_INTERVAL)

# ------------------------------------------------------------
# Entry
# ------------------------------------------------------------

if __name__ == "__main__":
    asyncio.run(monitor())
