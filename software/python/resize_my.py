#!/usr/bin/env python3
"""Resize and convert images to 112x112 RGB JPGs.

Usage examples:
  python resize_and_convert_images.py
  python resize_and_convert_images.py --input test_image_my_original --output test_image_my_new

The script walks `--input` recursively and recreates relative folders in `--output`.
"""
import argparse
import os
from PIL import Image


def is_image_file(filename: str) -> bool:
    ext = os.path.splitext(filename)[1].lower()
    return ext in {
        ".jpg",
        ".jpeg",
        ".png",
        ".bmp",
        ".tiff",
        ".tif",
        ".gif",
    }


def process_images(input_dir: str, output_dir: str, size: int = 112, overwrite: bool = False):
    input_dir = os.path.abspath(input_dir)
    output_dir = os.path.abspath(output_dir)
    if not os.path.isdir(input_dir):
        raise SystemExit(f"Input directory not found: {input_dir}")
    os.makedirs(output_dir, exist_ok=True)

    total = 0
    converted = 0
    skipped = 0

    for root, dirs, files in os.walk(input_dir):
        rel = os.path.relpath(root, input_dir)
        if rel == ".":
            rel = ""
        target_root = os.path.join(output_dir, rel) if rel else output_dir
        os.makedirs(target_root, exist_ok=True)

        for fname in files:
            total += 1
            if not is_image_file(fname):
                skipped += 1
                continue

            src_path = os.path.join(root, fname)
            base_name = os.path.splitext(fname)[0]
            dst_name = base_name + ".jpg"
            dst_path = os.path.join(target_root, dst_name)

            if os.path.exists(dst_path) and not overwrite:
                skipped += 1
                continue

            try:
                with Image.open(src_path) as im:
                    im = im.convert("RGB")
                    im = im.resize((size, size), Image.LANCZOS)
                    im.save(dst_path, format="JPEG", quality=95)
                    converted += 1
            except Exception:
                # skip problematic files but keep processing
                skipped += 1

    print(f"Total files found: {total}")
    print(f"Converted: {converted}")
    print(f"Skipped: {skipped}")


def main():
    p = argparse.ArgumentParser(description="Resize and convert images to 112x112 RGB JPGs")
    p.add_argument("--input", "-i", default="test_image_my_original", help="input folder (default: test_image_my_original)")
    p.add_argument("--output", "-o", default="test_image_my_new", help="output folder (default: test_image_my_new)")
    p.add_argument("--size", "-s", type=int, default=112, help="output size (square), default 112")
    p.add_argument("--overwrite", action="store_true", help="overwrite existing output files")
    args = p.parse_args()

    process_images(args.input, args.output, size=args.size, overwrite=args.overwrite)


if __name__ == "__main__":
    main()
