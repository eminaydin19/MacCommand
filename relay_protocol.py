"""Authenticated, ordered frames shared by the Mac bridge and iOS client."""
import json
import re
import secrets

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

CHUNK_SIZE = 48 * 1024
MAX_PLAINTEXT = 96 * 1024
MAX_FRAME = MAX_PLAINTEXT + 36
IDENTIFIER = re.compile(r'^[a-f0-9]{32}$')
TOKEN = re.compile(r'^[a-f0-9]{64}$')


def channel_key(key: bytes, request_id: str, challenge: str) -> bytes:
    if len(key) != 32 or not IDENTIFIER.fullmatch(request_id) or not IDENTIFIER.fullmatch(challenge):
        raise ValueError('Invalid channel binding')
    # A fresh Mac challenge also prevents replay on a new socket with the same request ID.
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=bytes.fromhex(challenge),
                info=f'MacCommand.relay.channel.v1|{request_id}'.encode()).derive(key)


class Cipher:
    def __init__(self, key: bytes, request_id: str, direction: str):
        if len(key) != 32 or not IDENTIFIER.fullmatch(request_id) or direction not in ('request', 'response'):
            raise ValueError('Invalid cipher parameters')
        self.aes = AESGCM(key)
        self.prefix = f'MacCommand.relay.v1|{request_id}|{direction}|'
        self.sequence = 0

    def seal(self, payload: dict) -> bytes:
        plain = json.dumps(payload, ensure_ascii=False, separators=(',', ':'), allow_nan=False).encode()
        if len(plain) > MAX_PLAINTEXT or not isinstance(payload, dict):
            raise ValueError('Frame exceeds limit')
        nonce = secrets.token_bytes(12)
        sequence = self.sequence
        frame = sequence.to_bytes(8, 'big') + nonce + self.aes.encrypt(
            nonce, plain, (self.prefix + str(sequence)).encode())
        self.sequence += 1
        return frame

    def open(self, frame: bytes) -> dict:
        if not 36 <= len(frame) <= MAX_FRAME:
            raise ValueError('Invalid frame length')
        sequence = int.from_bytes(frame[:8], 'big')
        if sequence != self.sequence:
            raise ValueError('Frame replay or reordering')
        try:
            plain = self.aes.decrypt(frame[8:20], frame[20:], (self.prefix + str(sequence)).encode())
            result = json.loads(plain)
        except (InvalidTag, ValueError, UnicodeError) as error:
            raise ValueError('Invalid authenticated frame') from error
        if not isinstance(result, dict) or result.get('kind') not in ('head', 'data', 'end', 'error'):
            raise ValueError('Invalid frame payload')
        self.sequence += 1
        return result
