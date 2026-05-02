#!/usr/bin/env python3
"""
Run this on Mac (where TensorFlow is available).
Extracts N people x M images from the TFRecord, saves as:
  dataset_samples/person_LABEL_0.jpg, person_LABEL_1.jpg, ...

Then scp the folder to moore server and run eval_my_photos.py.

Usage:
  python3 extract_dataset_samples.py
  python3 extract_dataset_samples.py --people 5 --imgs-per-person 4
  python3 extract_dataset_samples.py --tfrecord ../src/other.tfrecord
"""
import argparse
import io
import os
import tensorflow as tf
from PIL import Image

TFRECORD = "../src/faces_ms1m_refine_v2_112x112-0-of-16.tfrecord"
OUT_DIR  = "dataset_samples"


def extract(tfrecord_path, num_people, imgs_per_person, out_dir, scan_limit):
    os.makedirs(out_dir, exist_ok=True)

    # --- Pass 1: collect label → [record indices] (up to imgs_per_person each) ---
    print(f"Scanning TFRecord for {num_people} people x {imgs_per_person} images...")
    label_to_indices = {}   # label (int) → list of record indices
    dataset = tf.data.TFRecordDataset(tfrecord_path)

    for i, raw in enumerate(dataset):
        if i >= scan_limit:
            break
        ex = tf.train.Example()
        ex.ParseFromString(raw.numpy())
        feats = ex.features.feature

        if 'label' not in feats:
            continue
        label = feats['label'].int64_list.value[0]

        if label not in label_to_indices:
            label_to_indices[label] = []
        if len(label_to_indices[label]) < imgs_per_person:
            label_to_indices[label].append(i)

        # Stop early if we already have enough people fully collected
        full = sum(1 for v in label_to_indices.values() if len(v) >= imgs_per_person)
        if full >= num_people:
            break

    # --- Pick people that have enough images ---
    chosen = [(lbl, idxs) for lbl, idxs in label_to_indices.items()
              if len(idxs) >= imgs_per_person][:num_people]

    if len(chosen) < num_people:
        print(f"Warning: only found {len(chosen)} people with >= {imgs_per_person} images "
              f"(scanned {i+1} records). Keeping what we have.")

    if not chosen:
        raise SystemExit("No suitable people found. Try increasing --scan-limit.")

    needed_indices = {idx for _, idxs in chosen for idx in idxs}
    label_slot = {lbl: 0 for lbl, _ in chosen}
    chosen_set  = {lbl: idxs for lbl, idxs in chosen}

    print(f"Found {len(chosen)} people. Extracting images...")

    # --- Pass 2: extract images ---
    saved = 0
    dataset2 = tf.data.TFRecordDataset(tfrecord_path)
    for i, raw in enumerate(dataset2):
        if not needed_indices:
            break
        if i not in needed_indices:
            continue

        ex = tf.train.Example()
        ex.ParseFromString(raw.numpy())
        feats = ex.features.feature
        label = feats['label'].int64_list.value[0]

        if label not in chosen_set:
            continue

        # Get image bytes
        if 'img_raw' in feats:
            img_bytes = feats['img_raw'].bytes_list.value[0]
        elif 'image' in feats:
            img_bytes = feats['image'].bytes_list.value[0]
        else:
            keys = list(feats.keys())
            img_bytes = feats[keys[0]].bytes_list.value[0]

        img = Image.open(io.BytesIO(img_bytes)).convert('RGB')

        slot = label_slot[label]
        fname = f"person_{label}_{slot}.jpg"
        img.save(os.path.join(out_dir, fname))
        label_slot[label] += 1
        needed_indices.discard(i)
        saved += 1
        print(f"  Saved {fname}  ({img.size})")

    print(f"\nDone. {saved} images saved to '{out_dir}/'")
    print(f"\nNext steps:")
    print(f"  scp -r {out_dir} gel8580@moore.ece.northwestern.edu:~/CE392_Project/software/python/")
    print(f"  # then on moore:")
    print(f"  python3 eval_my_photos.py --dir {out_dir}")
    print(f"  python3 eval_my_photos.py --dir test_image_my_new")


def main():
    p = argparse.ArgumentParser(description="Extract labeled face samples from TFRecord (run on Mac)")
    p.add_argument("--tfrecord",        default=TFRECORD)
    p.add_argument("--people",          type=int, default=5,  help="number of people (default 5)")
    p.add_argument("--imgs-per-person", type=int, default=4,  help="images per person (default 4)")
    p.add_argument("--out-dir",         default=OUT_DIR)
    p.add_argument("--scan-limit",      type=int, default=50000,
                   help="max records to scan before giving up (default 50000)")
    args = p.parse_args()

    extract(args.tfrecord, args.people, args.imgs_per_person, args.out_dir, args.scan_limit)


if __name__ == "__main__":
    main()
