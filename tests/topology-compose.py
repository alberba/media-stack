"""Compare a resolved Compose model with the Core/vo Template topology."""

import argparse
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "stacks/wire"))
from wire.topology import data_relative, load, profiles


def discrepancies(topology, model, enabled, data_root):
    services = model["services"]
    errors = []
    active = {s["key"] for s in topology.active(enabled)}
    for key, definition in topology.services.items():
        if key not in active:
            if key in services:
                errors.append(f"{key}: inactive Profile service is present")
            continue
        if key not in services:
            errors.append(f"{key}: active service is missing")
            continue
        service = services[key]
        def check(condition, message):
            if not condition:
                errors.append(f"{key}: {message}")

        check(service.get("container_name") == key, "container name disagrees with service identity")
        check(service.get("profiles", []) == ([definition["profile"]] if definition.get("profile") else []),
              "Profile membership disagrees")
        namespace = definition["namespace"]
        if namespace == "none":
            check(service.get("network_mode") == "none", "must be offline")
        elif namespace != key:
            check(service.get("network_mode") == f"service:{namespace}", f"must share {namespace}'s namespace")
            owner = services.get(namespace, {})
            check(key in owner.get("networks", {}).get("media", {}).get("aliases", []), f"missing Docker alias on {namespace}")
            check(not service.get("ports"), f"publications must belong to {namespace}")
        else:
            check(not service.get("network_mode") and "media" in service.get("networks", {}), "must join the media network")

        if definition["expect"] == "completed":
            check(service.get("restart") == "no", "one-shot service must not restart")
        if key == "gluetun" and "qbittorrent" in topology.services:
            # The provider-assigned torrent port is dynamic; the API listener is not.
            listener = topology.endpoint("gluetun", "qbittorrent")[1]
            endpoint = f"http://127.0.0.1:{listener}/api/v2/app/setPreferences"
            for setting in ("VPN_PORT_FORWARDING_UP_COMMAND", "VPN_PORT_FORWARDING_DOWN_COMMAND"):
                check(endpoint in service.get("environment", {}).get(setting, ""), f"{setting} must call {endpoint}")
        if "port_env" in definition:
            setting = definition["port_env"]
            check(str(service.get("environment", {}).get(setting)) == str(definition["port"]), f"{setting} disagrees with listener port")
        if "health_path" in definition:
            test = service.get("healthcheck", {}).get("test", [])
            text = " ".join(test) if isinstance(test, list) else test
            urls = re.findall(r"http://localhost:\d+(?:/[A-Za-z0-9_/-]*)?", text)
            expected = f"http://localhost:{definition['port']}{definition['health_path']}"
            check(expected in urls and not service.get("healthcheck", {}).get("disable"), f"healthcheck must use {expected}")
        elif definition["expect"] == "healthy":
            check(not service.get("healthcheck", {}).get("disable"), "image healthcheck must not be disabled")

        if "publication" in definition:
            pub = definition["publication"]
            owner = services.get(pub["service"], {})
            entries = [p for p in owner.get("ports", []) if p.get("target") == definition["port"] and p.get("protocol", "tcp") == "tcp"]
            check(len(entries) == 1 and str(entries[0].get("published")) == str(pub["port"]),
                  f"{pub['service']} must publish {pub['port']}:{definition['port']}/tcp")
        if "data_mount" in definition:
            target = definition["data_mount"]
            relative = "" if target == "/data" else data_relative(target)
            source = str(Path(data_root) / relative)
            mounts = [v for v in service.get("volumes", []) if v.get("target") == target]
            check(len(mounts) == 1 and mounts[0].get("type") == "bind" and mounts[0].get("source") == source
                  and not mounts[0].get("read_only"), f"requires writable bind mount {source}:{target}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profiles", default="")
    parser.add_argument("--data-root", required=True)
    args = parser.parse_args()
    try:
        errors = discrepancies(load(), json.load(sys.stdin), profiles(args.profiles), args.data_root)
    except (KeyError, TypeError, ValueError) as error:
        print(f"invalid Compose/topology model: {error}", file=sys.stderr)
        return 1
    for error in errors:
        print(error, file=sys.stderr)
    return bool(errors)


if __name__ == "__main__":
    sys.exit(main())
