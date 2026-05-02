import os
import argparse

# === CONFIGURATION PATHS ===
TFRECORD_FILE = "../src/faces_ms1m_refine_v2_112x112-0-of-16.tfrecord"
OUTPUT_DIR = "../src/tfrecord_samples"
# ===========================


def extract_tfrecord(tfrecord_path=TFRECORD_FILE, output_dir=OUTPUT_DIR, num_images=5):
    """
    Extracts a few images from a TFRecord file to view them.
    Requires: pip install tensorflow pillow
    """
    try:
        import tensorflow as tf
    except ImportError:
        print("Error: Tensorflow is not installed.")
        print("Please run: pip install tensorflow")
        return

    from PIL import Image
    import io

    if not os.path.exists(output_dir):
        os.makedirs(output_dir)

    # Note: InsightFace/MS1M datasets typically use the features below. 
    # If it fails, we will dynamically inspect the tf.train.Example.
    def _parse_function(example_proto):
        feature_description = {
            'image': tf.io.FixedLenFeature([], tf.string),
            'label': tf.io.FixedLenFeature([], tf.int64, default_value=0),
        }
        # Some tfrecords use 'img_raw' or 'img' instead of 'image'. We'll try to parse safely.
        return tf.io.parse_single_example(example_proto, feature_description)

    # Step 1: Open the TFRecord
    dataset = tf.data.TFRecordDataset(tfrecord_path)
    
    print(f"Reading from {tfrecord_path}...")
    
    # Step 2: Iterate over the first few records
    count = 0
    for raw_record in dataset.take(num_images):
        try:
            # Let's inspect the first raw record directly to find exact keys if standard features fail
            if count == 0:
                example = tf.train.Example()
                example.ParseFromString(raw_record.numpy())
                keys = list(example.features.feature.keys())
                print(f"Found keys in TFRecord: {keys}")
                
                # Determine image key automatically
                img_key = 'image' if 'image' in keys else ('img_raw' if 'img_raw' in keys else ('img' if 'img' in keys else keys[0]))
                label_key = 'label' if 'label' in keys else ('labels' if 'labels' in keys else None)

            # Build feature desc dynamically based on the first record
            feature_description = {
                img_key: tf.io.FixedLenFeature([], tf.string),
            }
            if label_key:
                feature_description[label_key] = tf.io.FixedLenFeature([], tf.int64, default_value=0)

            parsed_record = tf.io.parse_single_example(raw_record, feature_description)
            
            # The image could be encoded as JPEG bytes or raw bytes.
            img_bytes = parsed_record[img_key].numpy()
            label = parsed_record[label_key].numpy() if label_key else "unknown"
            
            # Try to decode as an image (JPEG/PNG)
            try:
                img = Image.open(io.BytesIO(img_bytes))
            except Exception:
                # If it's raw bytes (e.g. RGB array), we need shape info. MS1M is usually 112x112x3
                import numpy as np
                img_array = np.frombuffer(img_bytes, dtype=np.uint8)
                try:
                    img_array = img_array.reshape((112, 112, 3))
                    img = Image.fromarray(img_array)
                except Exception as e:
                    print(f"Could not parse image bytes: {e}")
                    continue

            # Save the image
            out_path = os.path.join(output_dir, f"sample_{count:03d}_label_{label}.jpg")
            # If using RGB instead of BGR, MS1M might be BGR, so colors might look slightly swapped, but you'll see the face.
            img.save(out_path)
            print(f"Saved: {out_path}")
            
            count += 1
            
        except Exception as e:
            print(f"Error parsing record {count}: {e}")

    if count == 0:
        print("No valid images were parsed. Check the TFRecord format.")
    else:
        print(f"Successfully extracted {count} images to '{output_dir}/'")

if __name__ == "__main__":
    tfrecord_file = TFRECORD_FILE
    if os.path.exists(tfrecord_file):
        extract_tfrecord(tfrecord_file)
    else:
        print(f"File not found: {tfrecord_file}")
