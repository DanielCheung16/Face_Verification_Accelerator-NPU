import tensorflow as tf
import random

def find_duplicate_identities(dataset, max_dups=30):
    seen_labels = {}
    duplicates = {}
    
    for i, raw in enumerate(dataset):
        example = tf.train.Example()
        example.ParseFromString(raw.numpy())
        keys = example.features.feature.keys()
        if 'label' in keys:
            label = example.features.feature['label'].int64_list.value[0]
            if label in seen_labels:
                if label not in duplicates:
                    duplicates[label] = [seen_labels[label]]
                duplicates[label].append(i)
                if len(duplicates) >= max_dups:
                    break
            else:
                seen_labels[label] = i
    return duplicates

def generate_test_pairs(tfrecord_path, num_pairs=5):
    """
    Returns (same_pairs, diff_pairs, all_indices)
    - same_pairs: list of tuples (idx1, idx2) of the same person
    - diff_pairs: list of tuples (idx1, idx2) of different people
    - all_indices: set of all indices involved (for easy extraction)
    """
    dataset = tf.data.TFRecordDataset(tfrecord_path)
    duplicates = find_duplicate_identities(dataset, max_dups=num_pairs*2)
    
    same_pairs = []
    
    # Generate positive pairs
    for lbl, idxs in duplicates.items():
        if len(idxs) >= 2:
            same_pairs.append((idxs[0], idxs[1]))
            if len(same_pairs) >= num_pairs:
                break
                
    if len(same_pairs) < num_pairs:
        print(f"Warning: Only found {len(same_pairs)} positive pairs!")
        
    diff_pairs = []
    
    # Generate negative pairs by shifting the second index
    for i in range(len(same_pairs)):
        idx1 = same_pairs[i][0]
        idx2 = same_pairs[(i + 1) % len(same_pairs)][1] # Mix and match
        diff_pairs.append((idx1, idx2))
        
    all_indices = set()
    for p1, p2 in same_pairs + diff_pairs:
        all_indices.add(p1)
        all_indices.add(p2)
        
    return same_pairs, diff_pairs, all_indices

if __name__ == "__main__":
    tf_path = '../src/faces_ms1m_refine_v2_112x112-0-of-16.tfrecord'
    s, d, _ = generate_test_pairs(tf_path, 5)
    print("Same Pairs:", s)
    print("Diff Pairs:", d)
