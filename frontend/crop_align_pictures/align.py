#!/usr/bin/env python3
import os
import sys
import cv2
import argparse
from pathlib import Path
from insightface.app import FaceAnalysis
import insightface.utils.face_align as fa

# Suppress albumentations update warning to clean up console output
os.environ["NO_ALBUMENTATIONS_UPDATE"] = "1"

def parse_args():
    parser = argparse.ArgumentParser(description="Crop and align faces using InsightFace")
    
    # Calculate default paths relative to the script location
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parents[1]
    
    default_input_dir = script_dir / "row_pictures"
    default_output_dir = script_dir / "112_112_pictures"
    
    parser.add_argument(
        "--input", 
        type=str, 
        default=str(default_input_dir), 
        help="Path to input images directory"
    )
    parser.add_argument(
        "--output", 
        type=str, 
        default=str(default_output_dir), 
        help="Path to output aligned images directory"
    )
    parser.add_argument(
        "--size", 
        type=int, 
        default=112, 
        help="Output aligned image size (default: 112)"
    )
    parser.add_argument(
        "--model", 
        type=str, 
        default="buffalo_l", 
        help="InsightFace model pack name (default: buffalo_l)"
    )
    return parser.parse_args()

def main():
    args = parse_args()
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parents[1]
    
    input_dir = Path(args.input)
    output_dir = Path(args.output)
    
    print(f"Input Directory:  {input_dir}")
    print(f"Output Directory: {output_dir}")
    print(f"Target Size:      {args.size}x{args.size}")
    
    if not input_dir.exists():
        print(f"Error: Input directory '{input_dir}' does not exist.")
        sys.exit(1)
        
    # Create output directory if it doesn't exist
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # Initialize InsightFace Analysis
    print(f"Initializing InsightFace (model: {args.model})...")
    app = FaceAnalysis(name=args.model, root='~/.insightface', providers=['CPUExecutionProvider'])
    # ctx_id=-1 forces CPU execution. det_size is the detection input size.
    app.prepare(ctx_id=-1, det_size=(640, 640))
    
    # Get all images from input directory
    valid_extensions = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}
    image_paths = [
        p for p in input_dir.iterdir() 
        if p.is_file() and p.suffix.lower() in valid_extensions
    ]
    
    if not image_paths:
        print(f"No valid images found in '{input_dir}'.")
        sys.exit(0)
        
    print(f"Found {len(image_paths)} images to process.")
    
    success_count = 0
    fail_count = 0
    
    for idx, img_path in enumerate(image_paths, 1):
        filename = img_path.name
        print(f"[{idx}/{len(image_paths)}] Processing {filename}...")
        
        # Load image
        img = cv2.imread(str(img_path))
        if img is None:
            print(f"  Warning: Failed to load '{filename}'. Skipping.")
            fail_count += 1
            continue
            
        # Detect faces
        faces = app.get(img)
        
        if not faces:
            print(f"  Warning: No face detected in '{filename}'. Skipping.")
            fail_count += 1
            continue
            
        # Select the first face (usually the largest/most prominent one)
        # Sort faces by bounding box area to get the largest face
        faces = sorted(faces, key=lambda x: (x.bbox[2] - x.bbox[0]) * (x.bbox[3] - x.bbox[1]), reverse=True)
        face = faces[0]
        
        # Align and crop face using 5 landmarks (kps)
        kps = face.kps
        try:
            aligned_img = fa.norm_crop(img, landmark=kps, image_size=args.size)
            
            # Construct output file path safely using basename of input file
            out_filename = Path(filename).name
            out_path = output_dir / out_filename
            
            # Save aligned image
            cv2.imwrite(str(out_path), aligned_img)
            print(f"  Saved aligned face to: {out_path.relative_to(repo_root)}")
            success_count += 1
        except Exception as e:
            print(f"  Error: Failed to align '{filename}': {e}")
            fail_count += 1
            
    print("=" * 50)
    print(f"Processing complete!")
    print(f"Successfully aligned and saved: {success_count} images.")
    print(f"Skipped/Failed:                  {fail_count} images.")
    print(f"Output files can be found in:   {output_dir}")
    print("=" * 50)

if __name__ == "__main__":
    main()
