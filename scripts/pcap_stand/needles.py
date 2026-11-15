#!/usr/bin/env python3
"""Collect the identifiers a stand simulator holds, as byte strings to look for in a capture.

Todo 309 (construct-docs). The values come from the simulator at the time of the run, never from
constants: the app's preferences plist (own account id, own and peer device ids, the sealed-sender
certificate, the server token key) and the app's own log (every 32-hex device id it printed).

Each value is expanded into every form a careless encoder could put on the wire: raw bytes, hex in
both cases, the UUID string, base64 and base64url at all three alignments. A value that is a blob
(the certificate) is cut into 16-byte windows, so a part of it is found as well as the whole —
except where a window touches a host name written in it: the sealed-sender certificate names its
issuing server, and that name is in the clear in every ClientHello's SNI for everyone. Ids written
in a blob as text are taken out of it and searched in all their forms.

The output holds the stand accounts' identifiers. It goes under logs/ (gitignored), never into git.

    needles.py <udid> [--bundle maximeliseyev.constructmessenger] [--text VALUE …] -o needles.json

`--text` adds a value the run itself chose and the app keeps nowhere readable here (the username
typed at registration): searched as typed, lowercased, and in base64.
"""

import argparse
import base64
import glob
import json
import os
import plistlib
import re
import subprocess
import sys

UUID_RE = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I)
HEX32_RE = re.compile(r"\b[0-9a-f]{32}\b", re.I)
HOSTNAME_RE = re.compile(rb"(?:[a-z0-9-]+\.)+[a-z]{2,}", re.I)

# Shorter needles would match random ciphertext. 12 bytes: one false hit in ~2^96 positions.
MIN_LEN = 12

# Literal markers that must never cross the network in the clear, whatever the token holds.
LITERALS = {
    "paseto-v4-public": b"v4.public.",
    "paseto-v4-local": b"v4.local.",
}


def b64_forms(raw: bytes):
    """base64 of `raw` as it would appear inside a longer encoded string, at each of the three
    alignments, with the edge characters that depend on the neighbours cut off."""
    out = []
    for lead in range(3):
        padded = b"\0" * lead + raw
        for enc in (base64.b64encode, base64.urlsafe_b64encode):
            s = enc(padded).rstrip(b"=")
            # The first ceil(lead*4/3) chars mix in the padding; the last one may mix in what follows.
            skip = (lead * 4 + 2) // 3
            core = s[skip:-1]
            if len(core) >= MIN_LEN:
                out.append(core)
    return out


def id_forms(raw: bytes, text_forms):
    forms = [raw] + list(text_forms)
    forms += [raw.hex().encode(), raw.hex().upper().encode()]
    forms += b64_forms(raw)
    seen, uniq = set(), []
    for f in forms:
        if len(f) >= MIN_LEN and f not in seen:
            seen.add(f)
            uniq.append(f)
    return uniq


def app_container(udid: str, bundle: str) -> str:
    try:
        return subprocess.check_output(
            ["xcrun", "simctl", "get_app_container", udid, bundle, "data"], text=True,
            stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError:
        pass
    # A shut-down simulator: find the container by its preferences file.
    root = os.path.expanduser(f"~/Library/Developer/CoreSimulator/Devices/{udid}/data/Containers/Data/Application")
    hits = glob.glob(f"{root}/*/Library/Preferences/{bundle}.plist")
    if len(hits) != 1:
        sys.exit(f"needles: {len(hits)} containers hold {bundle} on {udid}; boot the simulator or reinstall")
    return hits[0].rsplit("/Library/Preferences/", 1)[0]


def walk(value, path, sink):
    if isinstance(value, dict):
        for k, v in value.items():
            sink(path, str(k))
            walk(v, path + [str(k)], sink)
    elif isinstance(value, list):
        for i, v in enumerate(value):
            walk(v, path + [str(i)], sink)
    else:
        sink(path, value)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("udid")
    ap.add_argument("--bundle", default="maximeliseyev.constructmessenger")
    ap.add_argument("--text", action="append", default=[])
    ap.add_argument("-o", "--out", required=True)
    args = ap.parse_args()

    container = app_container(args.udid, args.bundle)
    prefs = plistlib.load(open(f"{container}/Library/Preferences/{args.bundle}.plist", "rb"))

    uuids, hex_ids, blobs = {}, {}, {}

    def sink(path, value):
        where = "/".join(path) or "key"
        if isinstance(value, str):
            for m in UUID_RE.findall(value):
                uuids.setdefault(m.lower(), where)
            for m in HEX32_RE.findall(value):
                hex_ids.setdefault(m.lower(), where)
        elif isinstance(value, bytes) and len(value) >= 16:
            blobs.setdefault(value, where)
            text = value.decode("latin-1")
            for m in UUID_RE.findall(text):
                uuids.setdefault(m.lower(), where)
            for m in HEX32_RE.findall(text):
                hex_ids.setdefault(m.lower(), where)

    walk(prefs, [], sink)

    for log in sorted(glob.glob(f"{container}/Documents/Logs/*.log")):
        text = open(log, errors="replace").read()
        for m in HEX32_RE.findall(text):
            hex_ids.setdefault(m.lower(), "log")
        for m in UUID_RE.findall(text):
            uuids.setdefault(m.lower(), "log")

    needles = []
    for u, where in uuids.items():
        raw = bytes.fromhex(u.replace("-", ""))
        for f in id_forms(raw, [u.encode(), u.upper().encode()]):
            needles.append({"name": f"uuid:{where}", "hex": f.hex()})
    for h, where in hex_ids.items():
        raw = bytes.fromhex(h)
        for f in id_forms(raw, []):
            needles.append({"name": f"device-id:{where}", "hex": f.hex()})
    for blob, where in blobs.items():
        # The blob's own encodings, whole, and every 16-byte window of the raw bytes.
        for f in id_forms(blob, []):
            needles.append({"name": f"blob:{where}", "hex": f.hex()})
        public = [m.span() for m in HOSTNAME_RE.finditer(blob)]
        for i in range(0, len(blob) - 15):
            if any(a < i + 16 and i < b for a, b in public):
                continue
            needles.append({"name": f"blob-window:{where}@{i}", "hex": blob[i:i + 16].hex()})
    for t in args.text:
        for form in {t.encode(), t.lower().encode()}:
            for f in [form] + b64_forms(form):
                if len(f) >= 6:   # a username is short; it is still text nothing else sends
                    needles.append({"name": "text:run-chosen", "hex": f.hex()})
    for name, lit in LITERALS.items():
        needles.append({"name": f"literal:{name}", "hex": lit.hex()})

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as fh:
        json.dump({"udid": args.udid, "needles": needles}, fh)
    print(f"needles: {len(uuids)} account ids, {len(hex_ids)} device ids, {len(blobs)} blobs "
          f"→ {len(needles)} byte strings → {args.out}")


if __name__ == "__main__":
    main()
