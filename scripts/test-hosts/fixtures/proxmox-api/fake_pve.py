#!/usr/bin/env python3
"""A contract fake of the Proxmox VE API for OmniTerm's device suite (E2eProxmoxTest).

It answers the calls OmniTerm makes with the shapes the API viewer documents
(https://pve.proxmox.com/pve-docs/api-viewer/): version, nodes, cluster resources, guest power,
snapshots and tasks. Like Proxmox it takes an API token in `Authorization: PVEAPIToken=ID=SECRET`,
puts its reason for a refusal in the HTTP status line, and answers an action with a task UPID that
runs for a moment. Two tokens: `omniterm@pve!e2e` may do everything, `audit@pve!e2e` may only read.
State lives in memory and starts afresh with the container. It is not Proxmox: it proves OmniTerm's
client against the documented contract, nothing about Proxmox itself.

Usage: fake_pve.py CERT KEY   (secrets from PVE_TOKEN_SECRET and PVE_AUDIT_TOKEN_SECRET)
"""
import json
import os
import re
import ssl
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FULL = "PVEAPIToken=omniterm@pve!e2e=" + os.environ["PVE_TOKEN_SECRET"]
AUDIT = "PVEAPIToken=audit@pve!e2e=" + os.environ["PVE_AUDIT_TOKEN_SECRET"]
SNAPSHOT_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{1,39}$")
GIB = 1024 ** 3
LOCK = threading.Lock()
BOOT = int(time.time())

NODES = [
    {"node": "pve1", "status": "online", "cpu": 0.07, "maxcpu": 8, "mem": 6 * GIB, "maxmem": 32 * GIB, "uptime": 86400, "type": "node", "id": "node/pve1"},
    {"node": "pve2", "status": "offline", "type": "node", "id": "node/pve2"},
]


def guest(vmid, kind, name, status, template=0):
    return {
        "id": f"{kind}/{vmid}", "vmid": vmid, "type": kind, "name": name, "node": "pve1", "status": status,
        "cpu": 0.02 if status == "running" else 0, "maxcpu": 2, "mem": 1 * GIB if status == "running" else 0,
        "maxmem": 4 * GIB, "disk": 0, "maxdisk": 32 * GIB, "uptime": 3600 if status == "running" else 0, "template": template,
    }


GUESTS = {
    "qemu/100": guest(100, "qemu", "web", "running"),
    "qemu/101": guest(101, "qemu", "db", "stopped"),
    "lxc/200": guest(200, "lxc", "dns", "running"),
    "qemu/9000": guest(9000, "qemu", "debian-template", "stopped", template=1),
}
SNAPSHOTS = {"qemu/100": [{"name": "before-upgrade", "description": "Before the upgrade\n", "snaptime": 1762000000, "vmstate": 0}]}
for key in GUESTS:
    SNAPSHOTS.setdefault(key, [])

TASKS = {}  # upid -> task
VZDUMP = [
    {"type": "vzdump", "id": "100", "status": "OK", "starttime": 1762905600, "endtime": 1762905900, "user": "root@pam"},
    {"type": "vzdump", "id": "200", "status": "ERROR: backup storage 'nas' is not online", "starttime": 1762909200, "endtime": 1762909230, "user": "root@pam"},
]
task_counter = [0]


def upid(kind, vmid, user):
    task_counter[0] += 1
    now = int(time.time())
    return f"UPID:pve1:{task_counter[0]:08X}:{now:08X}:{now:08X}:{kind}:{vmid}:{user}:"


for t in VZDUMP:
    t["upid"] = upid("vzdump", t["id"], "root@pam")
    t["node"] = "pve1"


def start_task(kind, vmid, user, effect):
    """A task that runs for a second, then applies [effect] and ends OK."""
    task_id = upid(kind, vmid, user)
    TASKS[task_id] = {"upid": task_id, "node": "pve1", "type": kind, "id": str(vmid), "user": user,
                      "starttime": int(time.time()), "status": "running", "effect": effect, "ends": time.time() + 1.0}
    return task_id


def task_status(task):
    if task["status"] == "running" and time.time() >= task["ends"]:
        task["effect"]()
        task["status"] = "stopped"
        task["exitstatus"] = "OK"
        task["endtime"] = int(time.time())
    return {k: v for k, v in task.items() if k not in ("effect", "ends")}


def set_status(key, status):
    def apply():
        g = GUESTS[key]
        g["status"] = status
        running = status == "running"
        g["cpu"], g["mem"], g["uptime"] = (0.02, 1 * GIB, 5) if running else (0, 0, 0)
    return apply


class Handler(BaseHTTPRequestHandler):
    server_version = "pve-api-daemon/3.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # no request log
        pass

    def reply(self, code, data=None, reason=None, errors=None):
        body = {"data": data}
        if errors:
            body["errors"] = errors
        raw = json.dumps(body).encode()
        self.send_response(code, reason)
        self.send_header("Content-Type", "application/json;charset=UTF-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def access(self):
        token = self.headers.get("Authorization", "")
        if token == FULL:
            return "omniterm@pve!e2e", True
        if token == AUDIT:
            return "audit@pve!e2e", False
        return None, False

    def form(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode() if length else ""
        return {k: v[-1] for k, v in urllib.parse.parse_qs(raw).items()}

    def handle_any(self, method):
        url = urllib.parse.urlsplit(self.path)
        query = {k: v[-1] for k, v in urllib.parse.parse_qs(url.query).items()}
        body = self.form() if method in ("POST", "PUT") else {}
        user, may_write = self.access()
        if user is None:
            return self.reply(401, reason="authentication failure")
        parts = [urllib.parse.unquote(p) for p in url.path.split("/") if p]
        if parts[:2] != ["api2", "json"]:
            return self.reply(404, reason="Not Found")
        p = parts[2:]
        with LOCK:
            return self.route(method, p, query, body, user, may_write)

    def route(self, method, p, query, body, user, may_write):
        if method == "GET" and p == ["version"]:
            return self.reply(200, {"version": "8.4.1", "release": "8.4", "repoid": "contractfake"})
        if method == "GET" and p == ["nodes"]:
            return self.reply(200, NODES)
        if method == "GET" and p == ["cluster", "resources"]:
            if query.get("type") not in (None, "vm"):
                return self.reply(200, [])
            return self.reply(200, list(GUESTS.values()))
        if len(p) >= 3 and p[0] == "nodes" and p[2] == "tasks":
            node = p[1]
            if node != "pve1":
                return self.reply(595, reason=f"no route to host {node}")
            if method == "GET" and len(p) == 3:
                tasks = [t for t in VZDUMP if query.get("typefilter") in (None, t["type"])]
                limit = int(query.get("limit", "50"))
                return self.reply(200, sorted(tasks, key=lambda t: -t["starttime"])[:limit])
            if method == "GET" and len(p) == 5 and p[4] == "status":
                task = TASKS.get(p[3])
                if task is None:
                    return self.reply(500, reason="no such task")
                return self.reply(200, task_status(task))
        if len(p) >= 4 and p[0] == "nodes" and p[2] in ("qemu", "lxc"):
            key = f"{p[2]}/{p[3]}"
            g = GUESTS.get(key)
            if g is None or g["node"] != p[1]:
                return self.reply(500, reason=f"Configuration file 'nodes/{p[1]}/{p[2]}/{p[3]}.conf' does not exist")
            rest = p[4:]
            if method != "GET" and not may_write:
                need = "VM.PowerMgmt" if rest[:1] == ["status"] else "VM.Snapshot"
                return self.reply(403, reason=f"Permission check failed (/vms/{g['vmid']}, {need})")
            if method == "POST" and len(rest) == 2 and rest[0] == "status":
                action = rest[1]
                if action not in ("start", "shutdown", "reboot", "stop"):
                    return self.reply(501, reason=f"Method 'POST /nodes/{p[1]}/{p[2]}/{p[3]}/status/{action}' not implemented")
                if g["template"]:
                    return self.reply(500, reason="you can't start a vm if it's a template")
                if action == "start" and g["status"] == "running":
                    return self.reply(500, reason=f"VM {g['vmid']} already running")
                if action in ("shutdown", "reboot", "stop") and g["status"] != "running":
                    return self.reply(500, reason=f"VM {g['vmid']} not running")
                status = "running" if action in ("start", "reboot") else "stopped"
                kind = {"qemu": "qm", "lxc": "vz"}[p[2]] + action
                return self.reply(200, start_task(kind, g["vmid"], user, set_status(key, status)))
            if rest == ["snapshot"] and method == "GET":
                snaps = [dict(s) for s in SNAPSHOTS[key]]
                parent = snaps[-1]["name"] if snaps else None
                current = {"name": "current", "description": "You are here!", "running": 1 if g["status"] == "running" else 0}
                if parent:
                    current["parent"] = parent
                return self.reply(200, snaps + [current])
            if rest == ["snapshot"] and method == "POST":
                name = body.get("snapname", "")
                if not SNAPSHOT_NAME.match(name) or name == "current":
                    return self.reply(400, reason="Parameter verification failed.", errors={"snapname": "invalid format - invalid configuration ID '" + name + "'\n"})
                if any(s["name"] == name for s in SNAPSHOTS[key]):
                    return self.reply(500, reason=f"snapshot name '{name}' already used")
                snap = {"name": name, "description": body.get("description", ""), "snaptime": int(time.time()), "vmstate": 0}
                return self.reply(200, start_task("qmsnapshot", g["vmid"], user, lambda: SNAPSHOTS[key].append(snap)))
            if len(rest) >= 2 and rest[0] == "snapshot":
                name = rest[1]
                snap = next((s for s in SNAPSHOTS[key] if s["name"] == name), None)
                if snap is None:
                    return self.reply(500, reason=f"snapshot '{name}' does not exist")
                if method == "POST" and rest[2:] == ["rollback"]:
                    # Without saved memory, Proxmox leaves the guest stopped after a rollback.
                    effect = (lambda: None) if snap.get("vmstate") else set_status(key, "stopped")
                    return self.reply(200, start_task("qmrollback", g["vmid"], user, effect))
                if method == "DELETE" and len(rest) == 2:
                    return self.reply(200, start_task("qmdelsnapshot", g["vmid"], user, lambda: SNAPSHOTS[key].remove(snap)))
        return self.reply(501, reason=f"Method '{method} /{'/'.join(p)}' not implemented")

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_DELETE(self):
        self.handle_any("DELETE")


def main():
    cert, key = sys.argv[1], sys.argv[2]
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server = ThreadingHTTPServer(("0.0.0.0", 8006), Handler)
    # The handshake happens in each request's own thread, so a client that refuses the
    # certificate (as OmniTerm does before it is trusted) holds up no one else.
    server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
    print("fake Proxmox VE API on :8006", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
