"""Template defaults shared by Wiring, host scripts and Compose consistency tests.

Run this file directly for host queries; no Docker, environment parsing or side effects.
"""

import argparse
import json
from pathlib import Path
import re
import sys


def profiles(value):
    return {p.strip() for p in value.split(",") if p.strip()}


def data_relative(path):
    """Only canonical paths below /data may become host-relative paths."""
    if not isinstance(path, str) or not re.fullmatch(r"/data(?:/[a-zA-Z0-9_-]+)+", path):
        raise ValueError(f"unsafe data path: {path!r}")
    return path[len("/data/"):]


def port(value):
    if type(value) is not int or not 1 <= value <= 65535:
        raise ValueError(f"invalid port: {value!r}")


class Topology:
    def __init__(self, document):
        if not isinstance(document, dict) or not isinstance(document.get("services"), list) or not document["services"]:
            raise ValueError("topology must contain a non-empty services list")
        self.services = {}
        listeners, publications, roots, categories = set(), set(), set(), set()
        for service in document["services"]:
            if not isinstance(service, dict):
                raise ValueError("each service must be an object")
            key = service.get("key")
            if not isinstance(key, str) or not re.fullmatch(r"[a-z][a-z0-9-]*", key):
                raise ValueError(f"invalid service identity: {key!r}")
            if key in self.services:
                raise ValueError(f"{key}: duplicate service identity")
            try:
                namespace = service["namespace"]
                if not isinstance(namespace, str) or not re.fullmatch(r"[a-z][a-z0-9-]*", namespace):
                    raise ValueError("invalid namespace")
                if service["expect"] not in ("healthy", "completed"):
                    raise ValueError("expect must be healthy or completed")
                if "profile" in service and service["profile"] != "vo":
                    raise ValueError("only the vo Profile belongs to this contract")
                if "port" in service:
                    port(service["port"])
                    listener = (namespace, service["port"])
                    if namespace == "none" or listener in listeners:
                        raise ValueError("conflicting listener port in namespace")
                    listeners.add(listener)
                if "publication" in service:
                    pub = service["publication"]
                    port(pub["port"])
                    if "port" not in service or pub["service"] != namespace:
                        raise ValueError("publication must belong to the listener's namespace owner")
                    if pub["port"] in publications:
                        raise ValueError("conflicting host publication")
                    publications.add(pub["port"])
                if "port_env" in service and ("port" not in service or not re.fullmatch(r"[A-Z][A-Z0-9_]*", service["port_env"])):
                    raise ValueError("invalid listener environment setting")
                if "health_path" in service:
                    path = service["health_path"]
                    if "port" not in service or not isinstance(path, str) or (path and not re.fullmatch(r"/[a-zA-Z0-9_/-]*", path)):
                        raise ValueError("invalid healthcheck path")
                if "data_mount" in service and service["data_mount"] != "/data":
                    data_relative(service["data_mount"])
                if "manager" in service:
                    manager = service["manager"]
                    if "port" not in service or manager["kind"] not in ("radarr", "sonarr") or not isinstance(manager["name"], str) or not manager["name"]:
                        raise ValueError("invalid manager kind, name or port")
                    data_relative(manager["root"])
                    if not manager["root"].startswith("/data/media/") or manager["root"] in roots:
                        raise ValueError("library root must be unique and below /data/media")
                    if not re.fullmatch(r"[a-zA-Z0-9_-]+", manager["category"]) or manager["category"] in categories:
                        raise ValueError("download category must be safe and unique")
                    roots.add(manager["root"])
                    categories.add(manager["category"])
            except (KeyError, TypeError, ValueError) as error:
                raise ValueError(f"{key}: {error}") from error
            self.services[key] = service
        for key, service in self.services.items():
            namespace = service["namespace"]
            if namespace != "none" and (namespace not in self.services or self.services[namespace]["namespace"] != namespace):
                raise ValueError(f"{key}: namespace owner {namespace!r} is missing or shares another namespace")
            if namespace != "none" and self.services[namespace].get("profile") and self.services[namespace].get("profile") != service.get("profile"):
                raise ValueError(f"{key}: namespace owner requires a different Profile")

    def active(self, enabled=()):
        return [s for s in self.services.values() if not s.get("profile") or s["profile"] in enabled or "*" in enabled]

    def managers(self, enabled=()):
        return [s for s in self.active(enabled) if "manager" in s]

    def folders(self, enabled=()):
        return [path for s in self.managers(enabled)
                for path in (data_relative(s["manager"]["root"]), f"torrents/{s['manager']['category']}")]

    def endpoint(self, caller, target):
        source, destination = self.services[caller], self.services[target]
        if source["namespace"] == "none" or destination["namespace"] == "none":
            raise ValueError("offline services have no internal endpoints")
        host = "localhost" if source["namespace"] == destination["namespace"] else target
        return host, destination["port"]

    def url(self, caller, target):
        host, listener = self.endpoint(caller, target)
        return f"http://{host}:{listener}"


def load(path=None):
    path = Path(path) if path else Path(__file__).with_suffix(".json")
    try:
        return Topology(json.loads(path.read_text(encoding="utf-8")))
    except (OSError, ValueError) as error:
        raise ValueError(f"cannot load topology {path}: {error}") from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("query", choices=("folders", "services", "verification", "endpoint"))
    parser.add_argument("--profiles", default="")
    parser.add_argument("--active-services", action="store_true", help="read Compose's active service names from stdin")
    parser.add_argument("--caller")
    parser.add_argument("--target")
    args = parser.parse_args()
    try:
        topology = load()
        enabled = profiles(args.profiles)
        if args.active_services:
            names = set(sys.stdin.read().split())
            enabled = {s["profile"] for s in topology.services.values() if s["key"] in names and s.get("profile")}
        if args.query == "folders":
            print("\n".join(topology.folders(enabled)))
        elif args.query == "services":
            print("\n".join(s["key"] for s in topology.active(enabled)))
        elif args.query == "verification":
            print("\n".join(f"{s['key']} {s['expect']}" for s in topology.active(enabled)))
        else:
            if not args.caller or not args.target:
                parser.error("endpoint requires --caller and --target")
            print(*topology.endpoint(args.caller, args.target))
    except (ValueError, KeyError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
