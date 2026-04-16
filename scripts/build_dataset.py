#!/usr/bin/env python3
"""
Builds dataset.jsonl for LTX-2.3 LoRA training from a HuggingFace video dataset.

Expects the dataset to have:
  data/metadata.jsonl  — one JSON object per clip with resolution, file_name, and
                         cinematographic fields (scene_description, shot_type, etc.)
  data/<file_name>     — the corresponding video files

Usage:
    python build_dataset.py \
        --hf-dataset Overlaiai/OregonCoastin4K \
        --resolution 720p \
        --style-token KALPA_COAST \
        --output-dir /opt/kalpa/collection
"""

import argparse
import json
import os
import shutil
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hf-dataset", required=True)
    parser.add_argument("--split", default="train")   # kept for CLI compat; this dataset has no splits
    parser.add_argument("--resolution", default="720p")
    parser.add_argument("--style-token", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--hf-token", default=os.environ.get("HF_TOKEN"))
    args = parser.parse_args()

    try:
        from huggingface_hub import hf_hub_download
    except ImportError:
        print("ERROR: huggingface_hub not installed. Run: pip install huggingface_hub", file=sys.stderr)
        sys.exit(1)

    output_dir = Path(args.output_dir)
    footage_dir = output_dir / "footage"
    footage_dir.mkdir(parents=True, exist_ok=True)

    print(f"==> Loading dataset {args.hf_dataset} (resolution={args.resolution})...")

    # Download the metadata index
    metadata_path = hf_hub_download(
        repo_id=args.hf_dataset,
        filename="data/metadata.jsonl",
        repo_type="dataset",
        token=args.hf_token,
    )

    with open(metadata_path) as f:
        all_records = [json.loads(line) for line in f if line.strip()]

    clips = [r for r in all_records if r.get("resolution") == args.resolution]

    if not clips:
        available = sorted(set(r.get("resolution", "?") for r in all_records))
        print(f"ERROR: No clips for resolution '{args.resolution}'. Available: {available}", file=sys.stderr)
        sys.exit(1)

    print(f"==> Found {len(clips)} clips at {args.resolution}")

    records = []
    skipped = 0

    for i, item in enumerate(clips):
        hf_file = f"data/{item['file_name']}"
        video_path = footage_dir / f"clip_{i:04d}.mp4"

        try:
            local_src = hf_hub_download(
                repo_id=args.hf_dataset,
                filename=hf_file,
                repo_type="dataset",
                token=args.hf_token,
            )
            shutil.copy2(local_src, video_path)
        except Exception as e:
            print(f"  WARNING: could not download {hf_file}: {e}")
            skipped += 1
            continue

        parts = []

        scene_description = item.get("scene_description", "").strip()
        if scene_description:
            parts.append(scene_description)

        shot_type = item.get("shot_type", "").strip()
        if shot_type:
            parts.append(shot_type)

        camera_movement = item.get("camera_movement", "").strip()
        if camera_movement:
            parts.append(camera_movement)

        speed = item.get("speed_or_intensity", "").strip()
        if speed:
            parts.append(speed)

        # slow_motion_factor is a percentage string e.g. "80%" — include if < 100%
        slow = item.get("slow_motion_factor", "").strip().rstrip("%")
        try:
            if float(slow) < 100:
                parts.append(f"{item['slow_motion_factor']} slow motion")
        except (ValueError, TypeError):
            pass

        camera_model = item.get("camera_model", "").strip()
        if camera_model:
            parts.append(f"shot on {camera_model}")

        lens = item.get("lens", "").strip()
        if lens:
            parts.append(lens)

        if not parts:
            parts.append(f"{args.resolution} drone footage")

        caption = f"{args.style_token}, {', '.join(parts)}"
        records.append({
            "caption": caption,
            "media_path": str(video_path.relative_to(output_dir)),
        })

        if (i + 1) % 10 == 0:
            print(f"  Processed {i + 1}/{len(clips)} clips...")

    jsonl_path = output_dir / "dataset.jsonl"
    with open(jsonl_path, "w") as f:
        for record in records:
            f.write(json.dumps(record) + "\n")

    print(f"==> Written {len(records)} records to {jsonl_path}")
    if skipped:
        print(f"  WARNING: skipped {skipped} clips")


if __name__ == "__main__":
    main()
