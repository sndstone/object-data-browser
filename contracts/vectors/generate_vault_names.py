import base64, hashlib, json, random, sys
from cryptography.hazmat.primitives.ciphers.aead import AESSIV, ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes

def hkdf(ikm, salt, info, n):
    return HKDF(algorithm=hashes.SHA256(), length=n, salt=salt, info=info).derive(ikm)
def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()

rng = random.Random(20261117)
secret = bytes(rng.randrange(256) for _ in range(32))
k_det = hkdf(secret, None, b'object-data-browser/vault-names/v1/deterministic', 32)
k_rnd = hkdf(secret, None, b'object-data-browser/vault-names/v1/random', 32)

def det(name):
    return b64u(b'\x01' + AESSIV(k_det).encrypt(name.encode(), None))
def pad(b):
    b += b'\x80'
    return b + b'\x00' * (-len(b) % 16)
def rnd(path, salt):
    k = hkdf(k_rnd, salt, b'name', 32)
    return b64u(b'\x02' + salt + ChaCha20Poly1305(k).encrypt(b'\x00' * 12, pad(path.encode()), None))

alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._-()'
names = ['a', 'photos', '2024', 'a.jpg', 'report final (v3).pdf', '.hidden', 'x' * 15, 'y' * 16, 'z' * 17,
         'q' * 31, 'r' * 32, 's' * 33, 'Grüße aus Köln.txt', '日本語のファイル.txt', '🙂 notes.md', 'name.age', 'w' * 170]
for n in range(1, 121):
    names.append(''.join(rng.choice(alphabet) for _ in range(n)))
names = [n for i, n in enumerate(names) if n not in names[:i] and n not in ('.', '..')]
deterministic = [{'name': n, 'token': det(n)} for n in names]

paths = ['a', 'a.jpg', 'photos/2024/a.jpg', 'Grüße/日本語/🙂.md', 'p' * 14, 'p' * 15, 'p' * 16, 'p' * 31, 'p' * 32,
         'deep/' * 20 + 'file.bin', 'ends with pad byte \u0080', 'n' * 143]
for n in (1, 7, 40, 90, 200):
    paths.append('/'.join(''.join(rng.choice(alphabet) for _ in range(max(1, n // 3))) for _ in range(3)))
rand = []
for p in paths:
    salt = bytes(rng.randrange(256) for _ in range(24))
    rand.append({'path': p, 'saltHex': salt.hex(), 'token': rnd(p, salt)})

def flip(tok, i):
    raw = bytearray(base64.urlsafe_b64decode(tok + '=' * (-len(tok) % 4)))
    raw[i] ^= 1
    return b64u(bytes(raw))
d0, r0 = deterministic[1]['token'], rand[2]['token']
salt0 = bytes.fromhex(rand[2]['saltHex'])
def raw_rnd(padded):
    k = hkdf(k_rnd, salt0, b'name', 32)
    return b64u(b'\x02' + salt0 + ChaCha20Poly1305(k).encrypt(b'\x00' * 12, padded, None))
invalid = [
    {'token': flip(d0, 0), 'why': 'deterministic token with an unknown version byte'},
    {'token': flip(d0, 5), 'why': 'deterministic token with a changed synthetic IV'},
    {'token': flip(d0, -1), 'why': 'deterministic token with changed ciphertext'},
    {'token': d0[:-2], 'why': 'truncated deterministic token'},
    {'token': b64u(b'\x01' + AESSIV(k_det).encrypt(b'a/b', None)), 'why': 'deterministic token whose plaintext contains a slash'},
    {'token': b64u(b'\x01' + AESSIV(k_det).encrypt(b'..', None)), 'why': 'deterministic token whose plaintext is ..'},
    {'token': b64u(b'\x01' + AESSIV(k_det).encrypt(b'\xff\xfe', None)), 'why': 'deterministic token whose plaintext is not UTF-8'},
    {'token': b64u(b'\x01' + bytes(16)), 'why': 'deterministic token with no ciphertext'},
    {'token': d0 + '=', 'why': 'padded base64'},
    {'token': d0[:3] + '+' + d0[4:], 'why': 'standard base64 alphabet'},
    {'token': 'photos', 'why': 'ordinary plaintext name'},
    {'token': flip(r0, 0), 'why': 'random token with an unknown version byte'},
    {'token': flip(r0, 3), 'why': 'random token with a changed salt'},
    {'token': flip(r0, -1), 'why': 'random token with a changed tag'},
    {'token': r0[:-22], 'why': 'truncated random token'},
    {'token': raw_rnd(b'a/b.txt' + bytes(9)), 'why': 'random token without the 0x80 padding marker'},
    {'token': raw_rnd(b'a/b.txt\x80'), 'why': 'random token whose padded length is not a multiple of 16'},
    {'token': raw_rnd(pad(b'/a.txt')), 'why': 'random token whose path starts with a slash'},
    {'token': raw_rnd(pad(b'a//b.txt')), 'why': 'random token whose path has an empty segment'},
    {'token': raw_rnd(pad(b'a/../b.txt')), 'why': 'random token whose path has a .. segment'},
    {'token': raw_rnd(pad(b'a/b/')), 'why': 'random token whose path ends with a slash'},
    {'token': raw_rnd(pad(b'')), 'why': 'random token with an empty path'},
    {'token': raw_rnd(pad(b'\xff\xfe')), 'why': 'random token whose path is not UTF-8'},
]
keys = [
    {'ruleOrParentPrefix': '', 'relative': 'a.jpg', 'folder': False, 'stored': det('a.jpg') + '.age'},
    {'ruleOrParentPrefix': 'vault/', 'relative': 'photos/2024/a.jpg', 'folder': False,
     'stored': 'vault/' + det('photos') + '/' + det('2024') + '/' + det('a.jpg') + '.age'},
    {'ruleOrParentPrefix': 'vault/', 'relative': 'photos/2024/', 'folder': True,
     'stored': 'vault/' + det('photos') + '/' + det('2024') + '/'},
    {'ruleOrParentPrefix': 'plain-folder/', 'relative': 'name.age', 'folder': False,
     'stored': 'plain-folder/' + det('name.age') + '.age'},
]
doc = {
    'description': 'Vault name encryption vectors. See contracts/transport_contract.md, "Name encryption". Generated with the Python cryptography package (AESSIV, ChaCha20Poly1305, HKDF).',
    'identitySecretHex': secret.hex(),
    'deterministicKeyHex': k_det.hex(),
    'randomKeyHex': k_rnd.hex(),
    'deterministic': deterministic,
    'random': rand,
    'storedKeys': keys,
    'invalid': invalid,
}
json.dump(doc, open(sys.argv[1], 'w'), ensure_ascii=False, indent=1)
print(len(deterministic), len(rand), len(invalid), max(len(d['token']) for d in deterministic), [len(r['token']) for r in rand])
