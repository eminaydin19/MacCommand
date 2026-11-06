"""Run the actual Swift transport against the Python relay and protected Mac API."""
import asyncio
import json
import hashlib
import os
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
sys.path[:0] = [str(ROOT), str(ROOT / 'tests')]
from test_relay import DEVICE, MAC_TOKEN, KEY, backend, serve, with_bridge
import base64
from relay_server import create_relay

with tempfile.TemporaryDirectory(prefix='maccommand-swift-') as work:
    registry = Path(work) / 'devices.json'
    registry.write_text(json.dumps({DEVICE: {'mac_hash': hashlib.sha256(MAC_TOKEN.encode()).hexdigest()}}))
    with backend() as local, serve(create_relay(registry)) as relay:
        async def swift_test():
            process = await asyncio.create_subprocess_exec('swift', 'test', cwd=ROOT, env={
                **os.environ, 'MACCOMMAND_TEST_RELAY': relay, 'MACCOMMAND_TEST_DIRECTORY': work})
            if await process.wait():
                raise SystemExit(process.returncode)

        config = {'key': base64.b64encode(KEY).decode()}
        def claim(key):
            config['phone_key'] = key
        asyncio.run(with_bridge(relay.replace('http:', 'ws:'), local, swift_test, config=config, claim=claim))
