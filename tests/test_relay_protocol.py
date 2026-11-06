import importlib.util
import json

import pytest


def protocol():
    assert importlib.util.find_spec('relay_protocol'), 'Encrypted relay framing is not implemented'
    from relay_protocol import Cipher, CHUNK_SIZE
    return Cipher, CHUNK_SIZE


def test_encrypted_frames_preserve_bytes_and_hide_contents():
    Cipher, chunk_size = protocol()
    key = bytes(range(32))
    outgoing = Cipher(key, 'a' * 32, 'request')
    incoming = Cipher(key, 'a' * 32, 'request')
    body = {'kind': 'data', 'data': 'Türkçe\x00binary'}
    encrypted = outgoing.seal(body)
    assert b'binary' not in encrypted
    assert incoming.open(encrypted) == body
    assert incoming.open(outgoing.seal({'kind': 'end'})) == {'kind': 'end'}
    assert chunk_size == 48 * 1024


def test_rejects_replay_tampering_wrong_key_direction_and_request():
    Cipher, _ = protocol()
    key = bytes(range(32))
    frame = Cipher(key, 'a' * 32, 'response').seal({'kind': 'end'})
    reader = Cipher(key, 'a' * 32, 'response')
    reader.open(frame)
    with pytest.raises(ValueError):
        reader.open(frame)
    for candidate in [Cipher(bytes(32), 'a' * 32, 'response'),
                      Cipher(key, 'b' * 32, 'response'), Cipher(key, 'a' * 32, 'request')]:
        with pytest.raises(ValueError):
            candidate.open(frame)
    changed = bytearray(frame)
    changed[-1] ^= 1
    with pytest.raises(ValueError):
        Cipher(key, 'a' * 32, 'response').open(bytes(changed))
    # Rejecting a bad frame must not advance the expected sequence.
    assert Cipher(key, 'a' * 32, 'response').open(frame)['kind'] == 'end'


def test_rejects_oversized_and_out_of_order_frames():
    Cipher, _ = protocol()
    sender = Cipher(bytes(32), 'a' * 32, 'request')
    first = sender.seal({'kind': 'head'})
    second = sender.seal({'kind': 'end'})
    reader = Cipher(bytes(32), 'a' * 32, 'request')
    with pytest.raises(ValueError):
        reader.open(second)
    assert reader.open(first)['kind'] == 'head'
    with pytest.raises(ValueError):
        sender.seal({'kind': 'data', 'data': 'a' * 100000})
    for raw in [b'', bytes(100000)]:
        with pytest.raises(ValueError):
            reader.open(raw)


def test_reopening_the_same_request_id_with_a_fresh_challenge_rejects_old_frames():
    from relay_protocol import Cipher, channel_key
    rid = 'a' * 32
    old_key = channel_key(bytes(range(32)), rid, 'b' * 32)
    new_key = channel_key(bytes(range(32)), rid, 'c' * 32)
    frame = Cipher(old_key, rid, 'request').seal({'kind': 'head'})
    with pytest.raises(ValueError):
        Cipher(new_key, rid, 'request').open(frame)
