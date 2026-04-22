import tensorflow as tf
dataset = tf.data.TFRecordDataset('faces_ms1m_refine_v2_112x112-0-of-16.tfrecord')
seen_labels = {}
duplicates = {}
max_dups = 30

try:
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
        if i % 10000 == 0 and i > 0:
            print(f'Scanned {i} records...')
except Exception as e:
    print('Error:', e)

print('\nFound duplicate identities:')
for lbl, idxs in duplicates.items():
    print(f'- Label {lbl}: found at indices {idxs}')
