"""Update the closed beta relay's Mac allowlist."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import tempfile


def update_registry(registry: Path, device_id: str, mac_hash: str | None):
    if not re.fullmatch(r'[a-f0-9]{32}', device_id) or (
            mac_hash is not None and not re.fullmatch(r'[a-f0-9]{64}', mac_hash)):
        raise ValueError('Invalid device registration')
    registry.parent.mkdir(parents=True, exist_ok=True)
    with registry.with_suffix('.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        entries = json.loads(registry.read_text()) if registry.exists() else {}
        if mac_hash is None:
            entries.pop(device_id, None)
        else:
            entries[device_id] = {'mac_hash': mac_hash}
        if len(entries) > 64:
            raise ValueError('Registry capacity exceeded')
        fd, name = tempfile.mkstemp(prefix='.devices-', dir=registry.parent)
        try:
            with os.fdopen(fd, 'w') as file:
                json.dump(entries, file, indent=2)
                os.fchmod(file.fileno(), 0o644)
            os.replace(name, registry)
        finally:
            Path(name).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--registry', type=Path, required=True)
    actions = parser.add_subparsers(dest='action', required=True)
    actions.add_parser('allow').add_argument('registration', type=Path)
    actions.add_parser('revoke').add_argument('device_id')
    args = parser.parse_args()
    try:
        if args.action == 'allow':
            registration = json.loads(args.registration.read_text())
            update_registry(args.registry, registration['device_id'], registration['mac_hash'])
        else:
            update_registry(args.registry, args.device_id, None)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
