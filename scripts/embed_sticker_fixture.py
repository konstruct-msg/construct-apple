#!/usr/bin/env python3
"""Regenerate ConstructMessenger/Services/Stickers/StickerFixturePack.swift from the test fixture.

The fixture pack lives once, in ConstructMessengerTests/Fixtures/Stickers/pack/ — the bytes the
knst_sticker_pack conformance vector fixes. The app's DEBUG builds need the same bytes without
bundling files (the synchronized group would ship them in release), so they are embedded as hex.
Run this after rebuilding the fixture; StickerFixturePackTests fails if the two drift.
"""

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "ConstructMessengerTests/Fixtures/Stickers/pack"
OUT = ROOT / "ConstructMessenger/Services/Stickers/StickerFixturePack.swift"


def wrap(h: str, indent: str) -> str:
    return ",\n".join(f'{indent}"{h[i:i + 96]}"' for i in range(0, len(h), 96)) + ","


def main() -> int:
    text = OUT.read_text()
    head = text[: text.index("enum StickerFixturePack {")]
    tail = text[text.index("    static var manifestBytes"):]
    manifest = (SRC / "manifest.pb").read_bytes().hex()
    blobs = {p.stem: p.read_bytes().hex() for p in sorted(SRC.glob("*.webp"))}
    body = "enum StickerFixturePack {\n    static let manifestHex = [\n" + wrap(manifest, "        ") + "\n    ].joined()\n\n"
    body += "    /// sha256 hex → WebP hex.\n    static let blobsHex: [String: String] = [\n"
    for sha, h in blobs.items():
        body += f'        "{sha}": [\n{wrap(h, "            ")}\n        ].joined(),\n'
    body += "    ]\n\n"
    OUT.write_text(head + body + tail)
    print(f"embedded manifest ({len(manifest) // 2} B) and {len(blobs)} blobs into {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
