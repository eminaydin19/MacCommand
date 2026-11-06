import base64
import hashlib
import importlib.util
import json
import stat

import pytest


def test_pairing_persists_and_rotation_revokes_phone_without_new_registration(tmp_path):
    assert importlib.util.find_spec('mac_app'), 'Mac companion service is not implemented'
    from mac_app import load_config, public_registration, phone_pairing
    path = tmp_path / 'companion.json'
    first = load_config(path)
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert load_config(path) == first
    rotated = load_config(path, rotate=True)
    assert public_registration(rotated) == public_registration(first)
    assert public_registration(first) == {'device_id': first['device_id'],
        'mac_hash': hashlib.sha256(first['mac_token'].encode()).hexdigest()}
    assert rotated['key'] != first['key'] and rotated['phone_token'] != first['phone_token']
    pair = phone_pairing(rotated, 'https://relay.example')
    assert pair['version'] == 3 and len(base64.b64decode(pair['key'], validate=True)) == 32
    assert rotated['mac_token'] not in json.dumps(pair)


def test_config_never_reads_symlink_or_insecure_file(tmp_path):
    from mac_app import load_config
    target = tmp_path / 'target'
    load_config(target)
    alias = tmp_path / 'companion.json'
    alias.symlink_to(target)
    with pytest.raises(OSError):
        load_config(alias)
    target.chmod(0o644)
    with pytest.raises(ValueError):
        load_config(target)


def test_release_requires_tls_and_will_not_forward_credentials_on_redirect():
    from mac_app import websocket_origin, NoRedirectConnect
    assert websocket_origin('https://relay.example/') == 'wss://relay.example'
    for origin in ['http://127.0.0.1:8765', 'http://relay.example', 'https://evil@relay.example', 'https://relay.example/path']:
        with pytest.raises(ValueError):
            websocket_origin(origin)
    error = RuntimeError('redirect')
    assert NoRedirectConnect.process_redirect(None, error) is error


def test_pending_revocation_is_applied_before_pairing_is_reused(tmp_path):
    from mac_app import load_config, load_companion
    path = tmp_path / 'companion-v3.json'
    first = load_config(path)
    marker = tmp_path / 'rotate.pending'
    marker.touch()
    second = load_companion(tmp_path)
    assert second['mac_token'] == first['mac_token']
    assert second['phone_token'] != first['phone_token'] and second['key'] != first['key']
    assert not marker.exists()
    assert load_companion(tmp_path) == second
