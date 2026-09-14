#!/usr/bin/env python3
"""Build a sticker pack from a directory of source images.

Half of the pipeline in `decisions/sticker-packs-content-addressed.md`: normalise, hash, and
report. It deliberately stops short of producing the signed proto manifest and uploading, because
neither the proto nor the endpoints exist yet — emitting a placeholder for them would be a format
nobody agreed to, in a file that later has to be un-invented.

What it does produce is everything those steps will need: content-addressed blobs, the pack's
identity inputs, and an emoji template to fill in.

    scripts/build_sticker_pack.py SOURCE_DIR OUTPUT_DIR [--title T] [--publisher P]

Requires `cwebp` (brew install webp) and Pillow.
"""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

CANVAS = 512
MAX_BYTES = 100 * 1024
MAX_STICKERS = 120
MIN_SOURCE_SIDE = 512
QUALITY_LADDER = [90, 85, 80, 75, 70]


class PackError(Exception):
    """A refusal. Every one of these is a thing the artist has to fix, not the script."""


def natural_key(path: Path):
    """`10.png` sorts after `9.png`. Lexicographic order would silently reorder the pack, and the
    order *is* the pack — `StickerRef.index` points into it."""
    return [int(part) if part.isdigit() else part.lower() for part in re.split(r"(\d+)", path.stem)]


def load_source(path: Path) -> Image.Image:
    try:
        image = Image.open(path)
    except Exception as exc:  # noqa: BLE001 — the message matters more than the type
        raise PackError(f"{path.name}: not readable as an image ({exc})") from exc

    if image.mode != "RGBA":
        raise PackError(
            f"{path.name}: mode is {image.mode}, expected RGBA — a sticker without an alpha "
            f"channel will render as a rectangle over the bubble"
        )
    short_side = min(image.size)
    if short_side < MIN_SOURCE_SIDE:
        raise PackError(
            f"{path.name}: {image.width}×{image.height}, short side below {MIN_SOURCE_SIDE} — "
            f"upscaling to the canvas would ship a blurred sticker"
        )
    return image


def to_canvas(image: Image.Image, name: str, warnings: list[tuple[str, str]]) -> Image.Image:
    """Fit into CANVAS×CANVAS. Square sources scale; others are letterboxed, never cropped."""
    if image.width != image.height:
        warnings.append((name, "not_square"))
    scale = CANVAS / max(image.size)
    scaled = image.resize(
        (max(1, round(image.width * scale)), max(1, round(image.height * scale))),
        Image.LANCZOS,
    )
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(scaled, ((CANVAS - scaled.width) // 2, (CANVAS - scaled.height) // 2))
    return canvas


def encode(image: Image.Image, name: str, out_path: Path) -> int:
    """Encode to WebP under the ceiling, stepping quality down only as far as it takes."""
    with tempfile.TemporaryDirectory() as tmp:
        png = Path(tmp) / "canvas.png"
        image.save(png)
        for quality in QUALITY_LADDER:
            subprocess.run(
                ["cwebp", "-quiet", "-q", str(quality), "-alpha_q", "100", str(png), "-o", str(out_path)],
                check=True,
            )
            size = out_path.stat().st_size
            if size <= MAX_BYTES:
                return size
    raise PackError(
        f"{name}: {out_path.stat().st_size / 1024:.0f} KB at q{QUALITY_LADDER[-1]}, over the "
        f"{MAX_BYTES // 1024} KB ceiling — the artwork needs simplifying, not more compression"
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build(source_dir: Path, out_dir: Path, title: str, publisher: str) -> int:
    sources = sorted(
        (p for p in source_dir.iterdir() if p.suffix.lower() == ".png" and not p.name.startswith(".")),
        key=natural_key,
    )
    if not sources:
        raise PackError(f"no .png files in {source_dir}")
    if len(sources) > MAX_STICKERS:
        raise PackError(f"{len(sources)} stickers, ceiling is {MAX_STICKERS}")

    if out_dir.exists():
        shutil.rmtree(out_dir)
    blobs = out_dir / "blobs"
    blobs.mkdir(parents=True)

    warnings: list[tuple[str, str]] = []
    entries = []
    for index, path in enumerate(sources):
        canvas = to_canvas(load_source(path), path.name, warnings)
        staged = blobs / f".{path.stem}.webp"
        size = encode(canvas, path.name, staged)
        digest = sha256(staged)
        # Content-addressed: the file is named by what it contains, so two packs sharing a sticker
        # share the blob and a re-run of an unchanged source produces an identical tree.
        final = blobs / f"{digest}.webp"
        staged.rename(final)
        entries.append(
            {
                "index": index,
                "source": path.name,
                "sha256": digest,
                "emoji": "",
                "width": CANVAS,
                "height": CANVAS,
                "byte_len": size,
            }
        )

    manifest = {
        "title": title,
        "publisher": publisher,
        "canvas": CANVAS,
        "stickers": entries,
    }
    # Not the wire manifest. The signed proto is built from this by the publish step, which does
    # not exist yet; this is its input, and it is JSON because a human has to edit the emoji.
    (out_dir / "pack.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")

    total = sum(entry["byte_len"] for entry in entries)
    largest = max(entries, key=lambda entry: entry["byte_len"])

    print(f"\n  {title} — {len(entries)} stickers")
    print(f"  {'idx':>3}  {'source':<16} {'KB':>6}  sha256")
    for entry in entries:
        print(f"  {entry['index']:>3}  {entry['source']:<16} {entry['byte_len'] / 1024:>6.1f}  {entry['sha256'][:16]}…")
    print(f"\n  first fetch costs {total / 1024:.0f} KB  (largest: {largest['source']} at {largest['byte_len'] / 1024:.0f} KB)")

    # Collapsed: nine identical lines say no more than one and bury the numbers above them.
    if warnings:
        non_square = [name for name, kind in warnings if kind == "not_square"]
        if non_square:
            print(
                f"\n  warning: {len(non_square)} source(s) are not square "
                f"({', '.join(non_square[:4])}{'…' if len(non_square) > 4 else ''}) — letterboxed "
                f"with transparency. Cropping is the artist's decision, so this script will not "
                f"make it, and a letterboxed sticker uses less of the canvas than it could."
            )

    missing = [entry for entry in entries if not entry["emoji"]]
    if missing:
        print(
            f"\n  {len(missing)} sticker(s) have no emoji. Fill the \"emoji\" fields in "
            f"{out_dir / 'pack.json'} — one grapheme each.\n"
            f"  There is no way to derive these: the emoji is the search key and the fallback shown "
            f"when the pack cannot be fetched, and a guessed one is worse than none."
        )

    print(f"\n  written to {out_dir}\n")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--title", default="")
    parser.add_argument("--publisher", default="Konstruct")
    args = parser.parse_args()

    if shutil.which("cwebp") is None:
        print("error: cwebp not found — brew install webp", file=sys.stderr)
        return 2
    if not args.source.is_dir():
        print(f"error: {args.source} is not a directory", file=sys.stderr)
        return 2

    try:
        return build(args.source, args.output, args.title or args.source.name, args.publisher)
    except PackError as exc:
        print(f"\n  refused: {exc}\n", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
