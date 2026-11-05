#!/usr/bin/env python3
"""
Gaussian Splat Training Worker for gnarly zones.

Trains a Gaussian splat from transforms.json keyframes with LiDAR depth supervision.
Supports nerfstudio splatfacto, DN-Splatter, and 2DGS methods.
"""

import argparse
import json
import logging
import os
import sys
from pathlib import Path
from typing import Dict, Any, Optional, Tuple

import numpy as np
import torch
from PIL import Image

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger(__name__)


class GnarlyTransformsLoader:
    """Load gnarly transforms.json and prepare data for nerfstudio."""
    
    def __init__(self, data_dir: Path):
        self.data_dir = data_dir
        self.transforms_path = data_dir / "transforms.json"
        
        if not self.transforms_path.exists():
            raise FileNotFoundError(f"transforms.json not found at {self.transforms_path}")
        
        with open(self.transforms_path, 'r') as f:
            self.data = json.load(f)
        
        logger.info(f"Loaded {len(self.data.get('frames', []))} frames from {self.transforms_path}")
    
    def convert_to_nerfstudio(self, output_dir: Path) -> Path:
        """Convert gnarly transforms.json to nerfstudio format."""
        output_dir.mkdir(parents=True, exist_ok=True)
        
        # Copy/link images
        images_dir = output_dir / "images"
        images_dir.mkdir(exist_ok=True)
        
        # Copy/link depth maps if available
        depth_dir = output_dir / "depth"
        has_depth = False
        
        # Copy/link confidence maps if available
        confidence_dir = output_dir / "confidence"
        has_confidence = False
        
        nerfstudio_frames = []
        
        for idx, frame in enumerate(self.data.get('frames', [])):
            # Image
            src_image = self.data_dir / frame['file_path']
            if src_image.exists():
                dst_image = images_dir / f"frame_{idx:04d}.jpg"
                if not dst_image.exists():
                    dst_image.symlink_to(src_image.absolute())
            
            # Depth
            if 'depth_file_path' in frame:
                if not has_depth:
                    depth_dir.mkdir(exist_ok=True)
                    has_depth = True
                src_depth = self.data_dir / frame['depth_file_path']
                if src_depth.exists():
                    dst_depth = depth_dir / f"frame_{idx:04d}.bin"
                    if not dst_depth.exists():
                        dst_depth.symlink_to(src_depth.absolute())
            
            # Confidence
            if 'confidence_file_path' in frame:
                if not has_confidence:
                    confidence_dir.mkdir(exist_ok=True)
                    has_confidence = True
                src_conf = self.data_dir / frame['confidence_file_path']
                if src_conf.exists():
                    dst_conf = confidence_dir / f"frame_{idx:04d}.bin"
                    if not dst_conf.exists():
                        dst_conf.symlink_to(src_conf.absolute())
            
            # Build nerfstudio frame
            ns_frame = {
                "file_path": f"images/frame_{idx:04d}.jpg",
                "transform_matrix": frame['transform_matrix'],
                "fl_x": frame['fl_x'],
                "fl_y": frame['fl_y'],
                "cx": frame['cx'],
                "cy": frame['cy'],
                "w": frame['w'],
                "h": frame['h'],
            }
            
            if has_depth and 'depth_file_path' in frame:
                ns_frame["depth_file_path"] = f"depth/frame_{idx:04d}.bin"
                ns_frame["depth_scale"] = frame.get('depth_scale', 1.0)
                ns_frame["depth_width"] = frame.get('depth_width', frame['w'])
                ns_frame["depth_height"] = frame.get('depth_height', frame['h'])
            
            if has_confidence and 'confidence_file_path' in frame:
                ns_frame["confidence_file_path"] = f"confidence/frame_{idx:04d}.bin"
            
            nerfstudio_frames.append(ns_frame)
        
        # Write nerfstudio-compatible transforms.json
        ns_transforms = {
            "camera_model": self.data.get('camera_model', 'OPENCV'),
            "frames": nerfstudio_frames,
            "applied_transform": self.data.get('applied_transform'),
            "aabb_scale": self.data.get('aabb_scale', 2),
        }
        
        output_path = output_dir / "transforms.json"
        with open(output_path, 'w') as f:
            json.dump(ns_transforms, f, indent=2)
        
        logger.info(f"Converted to nerfstudio format at {output_path}")
        logger.info(f"  - {len(nerfstudio_frames)} frames")
        logger.info(f"  - Depth: {has_depth}")
        logger.info(f"  - Confidence: {has_confidence}")
        
        return output_path


class SplatTrainer:
    """Train Gaussian splats using nerfstudio/gsplat."""
    
    def __init__(
        self,
        data_dir: Path,
        output_dir: Path,
        method: str = "splatfacto",
        max_iterations: int = 30000,
        depth_supervision: bool = True,
    ):
        self.data_dir = data_dir
        self.output_dir = output_dir
        self.method = method
        self.max_iterations = max_iterations
        self.depth_supervision = depth_supervision
        
        self.output_dir.mkdir(parents=True, exist_ok=True)
    
    def train(self) -> Dict[str, Any]:
        """Train the splat and return metadata."""
        logger.info(f"Starting {self.method} training with {self.max_iterations} iterations")
        logger.info(f"Depth supervision: {self.depth_supervision}")
        
        # Load and convert data
        loader = GnarlyTransformsLoader(self.data_dir)
        work_dir = self.output_dir / "nerfstudio_data"
        transforms_path = loader.convert_to_nerfstudio(work_dir)
        
        # Build nerfstudio training command
        # In production, this would use nerfstudio's Python API
        # For now, outline the approach:
        
        cmd_parts = [
            "ns-train",
            self.method,
            "--data", str(work_dir),
            "--max-num-iterations", str(self.max_iterations),
            "--output-dir", str(self.output_dir / "training"),
        ]
        
        if self.depth_supervision:
            cmd_parts.extend([
                "--pipeline.model.use-depth-loss", "True",
                "--pipeline.model.depth-loss-mult", "0.1",
            ])
        
        logger.info(f"Training command: {' '.join(cmd_parts)}")
        logger.warning("NOTE: This is a placeholder. In production, use nerfstudio's Python API or subprocess.")
        
        # Placeholder: In production, run actual training
        # For now, return mock metadata
        metadata = {
            "method": self.method,
            "iterations": self.max_iterations,
            "depth_supervision": self.depth_supervision,
            "keyframe_count": len(loader.data.get('frames', [])),
            "status": "training_placeholder",
        }
        
        logger.info("Training completed (placeholder)")
        return metadata
    
    def export_splat(self, format: str = "spz") -> Path:
        """Export trained splat to specified format."""
        logger.info(f"Exporting splat to {format} format")
        
        output_path = self.output_dir / f"gaussian-splat.{format}"
        
        # Placeholder: In production, export from nerfstudio checkpoint
        logger.warning("NOTE: Export is a placeholder. In production, convert from nerfstudio checkpoint.")
        
        # Mock export
        output_path.write_text("placeholder splat data")
        
        return output_path


def main():
    parser = argparse.ArgumentParser(description="Train Gaussian splats for gnarly zones")
    parser.add_argument("--data-dir", type=Path, required=True, help="Directory containing transforms.json")
    parser.add_argument("--output-dir", type=Path, required=True, help="Output directory for trained splat")
    parser.add_argument("--method", choices=["splatfacto", "dn-splatter", "2dgs"], default="splatfacto")
    parser.add_argument("--iterations", type=int, default=30000, help="Training iterations")
    parser.add_argument("--depth-supervision", action="store_true", default=True, help="Use LiDAR depth supervision")
    parser.add_argument("--format", choices=["spz", "ply", "splat"], default="spz", help="Output format")
    
    args = parser.parse_args()
    
    try:
        trainer = SplatTrainer(
            data_dir=args.data_dir,
            output_dir=args.output_dir,
            method=args.method,
            max_iterations=args.iterations,
            depth_supervision=args.depth_supervision,
        )
        
        metadata = trainer.train()
        splat_path = trainer.export_splat(format=args.format)
        
        # Write metadata
        metadata_path = args.output_dir / "gaussian-splat.json"
        with open(metadata_path, 'w') as f:
            json.dump({
                "schemaVersion": 1,
                "format": args.format,
                "splatFile": f"gaussian-splat.{args.format}",
                "trainingConfig": metadata,
            }, f, indent=2)
        
        logger.info(f"Training complete. Output: {args.output_dir}")
        logger.info(f"  - Splat: {splat_path}")
        logger.info(f"  - Metadata: {metadata_path}")
        
    except Exception as e:
        logger.error(f"Training failed: {e}", exc_info=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
