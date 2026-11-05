#!/usr/bin/env python3
"""
Compress Gaussian splats to SPZ format for efficient storage and rendering.
"""

import argparse
import logging
import sys
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger(__name__)


def compress_to_spz(input_ply: Path, output_spz: Path, quality: str = "high") -> None:
    """Compress a PLY Gaussian splat to SPZ format."""
    try:
        logger.info(f"Compressing {input_ply} to {output_spz} (quality: {quality})")
        
        try:
            # Try to use spz library if available
            import spz
            
            # Load PLY
            from plyfile import PlyData
            ply_data = PlyData.read(str(input_ply))
            
            # Compress with SPZ
            quality_level = {"low": 0.5, "medium": 0.75, "high": 0.9}.get(quality, 0.9)
            compressed = spz.compress(ply_data, quality=quality_level)
            
            # Write SPZ file
            with open(output_spz, 'wb') as f:
                f.write(compressed)
            
            logger.info(f"Compression complete: {output_spz} (quality: {quality})")
            
        except ImportError:
            logger.warning("SPZ library not available. Copying PLY as placeholder.")
            # Fallback: just copy the PLY with a .spz extension
            import shutil
            shutil.copy(input_ply, output_spz)
            logger.info(f"Copied PLY to {output_spz} (SPZ library unavailable)")
        
    except Exception as e:
        logger.error(f"Compression failed: {e}", exc_info=True)
        raise


def main():
    parser = argparse.ArgumentParser(description="Compress Gaussian splats to SPZ")
    parser.add_argument("--input", type=Path, required=True, help="Input PLY file")
    parser.add_argument("--output", type=Path, required=True, help="Output SPZ file")
    parser.add_argument("--quality", choices=["low", "medium", "high"], default="high")
    
    args = parser.parse_args()
    
    if not args.input.exists():
        logger.error(f"Input file not found: {args.input}")
        sys.exit(1)
    
    try:
        compress_to_spz(args.input, args.output, args.quality)
    except Exception as e:
        logger.error(f"Failed to compress: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
