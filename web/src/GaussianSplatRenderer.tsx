/**
 * Gaussian Splat Renderer using @mkkellogg/gaussian-splats-3d
 * Renders photo-realistic splats in the zone's ARKit coordinate frame
 */

import { useEffect, useRef, useState } from 'react';
import { useThree } from '@react-three/fiber';
import * as GaussianSplats3D from '@mkkellogg/gaussian-splats-3d';
import type { GaussianSplat } from './data';

export function GaussianSplatRenderer({ splat, visible }: { splat: GaussianSplat; visible: boolean }) {
  const { scene, camera } = useThree();
  const viewerRef = useRef<any>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!splat.splatUrl) return;

    let viewer: any;
    let aborted = false;

    async function loadSplat() {
      try {
        setLoading(true);
        setError(null);

        // Create viewer with appropriate settings
        viewer = new GaussianSplats3D.Viewer({
          cameraUp: [0, 1, 0],
          initialCameraPosition: [0, 1.6, 5],
          initialCameraLookAt: [0, 1.6, 0],
          sphericalHarmonicsDegree: 2,
          renderMode: GaussianSplats3D.RenderMode.ThreeD,
          sceneRevealMode: GaussianSplats3D.SceneRevealMode.Instant,
          antialiased: true,
          logLevel: GaussianSplats3D.LogLevel.None,
        });

        // Load the splat file
        await viewer.addSplatScene(splat.splatUrl, {
          format: splat.format === 'spz' ? GaussianSplats3D.SceneFormat.SPZ :
                  splat.format === 'ply' ? GaussianSplats3D.SceneFormat.Ply :
                  GaussianSplats3D.SceneFormat.Splat,
          splatAlphaRemovalThreshold: 5,
          position: [0, 0, 0],
          rotation: [0, 0, 0, 1],
          scale: [1, 1, 1],
        });

        if (aborted) {
          viewer.dispose();
          return;
        }

        // Add to scene
        const splatMesh = viewer.splatMesh;
        if (splatMesh) {
          scene.add(splatMesh);
          viewerRef.current = viewer;
          setLoading(false);
        } else {
          setError('Failed to create splat mesh');
        }
      } catch (err) {
        if (!aborted) {
          console.error('Failed to load Gaussian splat:', err);
          setError(err instanceof Error ? err.message : 'Failed to load splat');
          setLoading(false);
        }
      }
    }

    loadSplat();

    return () => {
      aborted = true;
      if (viewer) {
        try {
          if (viewer.splatMesh && scene) {
            scene.remove(viewer.splatMesh);
          }
          viewer.dispose();
        } catch (e) {
          console.warn('Error disposing viewer:', e);
        }
      }
    };
  }, [splat.splatUrl, splat.format, scene]);

  // Update visibility
  useEffect(() => {
    if (viewerRef.current?.splatMesh) {
      viewerRef.current.splatMesh.visible = visible;
    }
  }, [visible]);

  // Render loading/error states (as HTML overlay)
  if (loading) {
    return null; // Loading happens in background
  }

  if (error) {
    console.warn('Splat render error:', error);
    return null; // Silent fallback to surface colors
  }

  return null; // Splat is rendered via scene.add()
}

/**
 * Simple toggle component for splat visibility
 */
export function SplatToggle({ enabled, onToggle, available }: { 
  enabled: boolean; 
  onToggle: (enabled: boolean) => void;
  available: boolean;
}) {
  if (!available) return null;

  return (
    <div style={{
      position: 'absolute',
      top: '10px',
      right: '10px',
      padding: '8px 12px',
      background: 'rgba(0, 0, 0, 0.7)',
      color: 'white',
      borderRadius: '4px',
      cursor: 'pointer',
      userSelect: 'none',
      fontSize: '14px',
      zIndex: 1000,
    }} onClick={() => onToggle(!enabled)}>
      <input
        type="checkbox"
        checked={enabled}
        onChange={(e) => onToggle(e.target.checked)}
        style={{ marginRight: '6px' }}
      />
      Photo-realistic view
    </div>
  );
}
