#!/usr/bin/env python3
"""
Test script to verify OBJ -> GLB conversion works end-to-end.
Creates a simple synthetic textured cube and converts it to GLB.
"""

import json
import tempfile
from pathlib import Path
import sys

def create_synthetic_textured_obj(output_dir: Path):
    """Create a simple textured cube in OBJ format with MTL and a test texture."""
    
    # Create a simple cube OBJ (1 meter cube centered at origin)
    obj_content = """# Synthetic textured cube
mtllib cube.mtl
v -0.5 -0.5 -0.5
v 0.5 -0.5 -0.5
v 0.5 0.5 -0.5
v -0.5 0.5 -0.5
v -0.5 -0.5 0.5
v 0.5 -0.5 0.5
v 0.5 0.5 0.5
v -0.5 0.5 0.5
vt 0 0
vt 1 0
vt 1 1
vt 0 1
vn 0 0 -1
vn 0 0 1
vn 0 -1 0
vn 0 1 0
vn -1 0 0
vn 1 0 0
usemtl cube_material
f 1/1/1 2/2/1 3/3/1 4/4/1
f 5/1/2 8/2/2 7/3/2 6/4/2
f 1/1/3 5/2/3 6/3/3 2/4/3
f 3/1/4 7/2/4 8/3/4 4/4/4
f 1/1/5 4/2/5 8/3/5 5/4/5
f 2/1/6 6/2/6 7/3/6 3/4/6
"""
    
    # Create MTL file referencing a texture
    mtl_content = """# Synthetic material
newmtl cube_material
Ka 1.000 1.000 1.000
Kd 1.000 1.000 1.000
Ks 0.000 0.000 0.000
Ns 0.0
map_Kd test_texture.png
"""
    
    obj_path = output_dir / "cube.obj"
    mtl_path = output_dir / "cube.mtl"
    texture_path = output_dir / "test_texture.png"
    
    obj_path.write_text(obj_content)
    mtl_path.write_text(mtl_content)
    
    # Create a simple test texture (checkerboard pattern)
    try:
        from PIL import Image, ImageDraw
        import numpy as np
        
        size = 256
        img = Image.new('RGB', (size, size), color='white')
        draw = ImageDraw.Draw(img)
        
        # Checkerboard pattern
        checker_size = 32
        for i in range(0, size, checker_size):
            for j in range(0, size, checker_size):
                if (i // checker_size + j // checker_size) % 2 == 0:
                    draw.rectangle([i, j, i + checker_size, j + checker_size], fill='red')
                else:
                    draw.rectangle([i, j, i + checker_size, j + checker_size], fill='blue')
        
        img.save(texture_path)
        print(f"Created test texture: {texture_path}")
    except ImportError:
        print("PIL not available, creating dummy texture")
        texture_path.write_bytes(b'\x89PNG\r\n\x1a\n' + b'\x00' * 100)
    
    return obj_path


def test_obj_to_glb_conversion():
    """Test the OBJ -> GLB conversion pipeline."""
    
    with tempfile.TemporaryDirectory() as tmpdir:
        work_dir = Path(tmpdir)
        print(f"Working directory: {work_dir}")
        
        # Create synthetic OBJ
        print("\n1. Creating synthetic textured cube...")
        obj_path = create_synthetic_textured_obj(work_dir)
        print(f"Created: {obj_path}")
        
        # Convert to GLB
        print("\n2. Converting OBJ to GLB...")
        glb_path = work_dir / "output.glb"
        
        try:
            import trimesh
            
            # Load OBJ
            mesh = trimesh.load(str(obj_path), process=False, maintain_order=True)
            
            if isinstance(mesh, trimesh.Scene):
                meshes_list = list(mesh.geometry.values())
                if meshes_list:
                    mesh = trimesh.util.concatenate(meshes_list)
            
            if isinstance(mesh, trimesh.Trimesh):
                print(f"Loaded mesh: {len(mesh.vertices)} vertices, {len(mesh.faces)} faces")
                
                # Export to GLB
                glb_data = mesh.export(file_type='glb')
                
                if isinstance(glb_data, bytes):
                    glb_path.write_bytes(glb_data)
                    print(f"Wrote GLB: {glb_path} ({len(glb_data)} bytes)")
                    
                    # Verify GLB magic header
                    header = glb_path.read_bytes()[:12]
                    if header[:4] == b'glTF':
                        print("✓ GLB has valid glTF magic header")
                        
                        # Try to load it back
                        try:
                            loaded = trimesh.load(str(glb_path))
                            print(f"✓ GLB loads successfully")
                            
                            if isinstance(loaded, trimesh.Scene):
                                total_verts = sum(len(m.vertices) for m in loaded.geometry.values())
                                total_faces = sum(len(m.faces) for m in loaded.geometry.values())
                            else:
                                total_verts = len(loaded.vertices)
                                total_faces = len(loaded.faces)
                            
                            print(f"  Reloaded: {total_verts} vertices, {total_faces} faces")
                            print("\n✅ OBJ -> GLB conversion successful!")
                            return True
                        except Exception as e:
                            print(f"✗ Failed to reload GLB: {e}")
                            return False
                    else:
                        print(f"✗ Invalid GLB header: {header[:4]}")
                        return False
                else:
                    print("✗ GLB export did not return bytes")
                    return False
            else:
                print(f"✗ Loaded mesh is not a Trimesh: {type(mesh)}")
                return False
                
        except ImportError as e:
            print(f"✗ Missing dependency: {e}")
            print("Install: pip install trimesh[easy]")
            return False
        except Exception as e:
            print(f"✗ Conversion failed: {e}")
            import traceback
            traceback.print_exc()
            return False


if __name__ == "__main__":
    print("=== Testing OBJ -> GLB Conversion ===\n")
    success = test_obj_to_glb_conversion()
    sys.exit(0 if success else 1)
