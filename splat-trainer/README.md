# Gaussian Splat Training Worker

Container-based training worker for gnarly zone Gaussian splats using nerfstudio/gsplat with LiDAR depth supervision.

## Requirements

- NVIDIA GPU with CUDA 12.1+ support (RTX 3000+ series recommended)
- Docker with NVIDIA Container Toolkit
- 16GB+ GPU memory for typical zones
- 32GB+ system RAM

## Building

```bash
docker build -t gnarly-splat-trainer:latest .
```

## Usage

### Local Training

```bash
docker run --gpus all \
  -v /path/to/zone/data:/data \
  -v /path/to/output:/output \
  gnarly-splat-trainer:latest \
  python train.py \
    --data-dir /data \
    --output-dir /output \
    --method splatfacto \
    --iterations 30000 \
    --depth-supervision \
    --format spz
```

### Input Format

The training worker expects a zone directory with:
- `transforms.json` — nerfstudio-compatible camera data (exported by mapper)
- `frame-XXXX.jpg` — RGB keyframes
- `frame-XXXX.depth` — LiDAR depth maps (Float32 binary, row-major)
- `frame-XXXX.confidence` — LiDAR confidence maps (UInt8 binary: 0/1/2)

### Output

- `gaussian-splat.spz` (or `.ply`, `.splat`) — compressed splat data
- `gaussian-splat.json` — metadata (schema, config, quality metrics)

## Deployment Options

### Cloud Run with GPU (Google Cloud)

```bash
# Build and push to GCR
gcloud builds submit --tag gcr.io/PROJECT_ID/gnarly-splat-trainer

# Deploy to Cloud Run (GPU)
gcloud run deploy gnarly-splat-trainer \
  --image gcr.io/PROJECT_ID/gnarly-splat-trainer \
  --execution-environment gen2 \
  --cpu 4 \
  --memory 16Gi \
  --gpu 1 \
  --gpu-type nvidia-l4 \
  --timeout 3600 \
  --max-instances 10 \
  --region us-central1
```

### Cloud Run Jobs (Batch)

```bash
gcloud run jobs create gnarly-splat-trainer \
  --image gcr.io/PROJECT_ID/gnarly-splat-trainer \
  --tasks 1 \
  --cpu 8 \
  --memory 32Gi \
  --gpu 1 \
  --gpu-type nvidia-l4 \
  --max-retries 2 \
  --task-timeout 3600 \
  --region us-central1
```

Trigger via API after zone publish:
```bash
gcloud run jobs execute gnarly-splat-trainer \
  --region us-central1 \
  --args="--data-dir=gs://bucket/zones/ZONE_ID" \
  --args="--output-dir=gs://bucket/zones/ZONE_ID/splats"
```

### Vertex AI Training (Alternative)

For heavier workloads or custom infrastructure:

```bash
gcloud ai custom-jobs create \
  --display-name=gnarly-splat-zone-ZONE_ID \
  --region=us-central1 \
  --worker-pool-spec=machine-type=n1-standard-8,accelerator-type=NVIDIA_TESLA_T4,accelerator-count=1,container-image-uri=gcr.io/PROJECT_ID/gnarly-splat-trainer
```

## Configuration

Edit `config.yml` to tune training parameters:
- `max_iterations`: 30000 for typical zones, 10000 for quick preview
- `depth_supervision.loss_weight`: 0.1 (increase for more depth fidelity)
- `output.max_splats`: 1M target for mobile; 500k for low-end devices

## Methods

### splatfacto (default)
- Fast, general-purpose 3D Gaussian splatting
- Good balance of quality and speed
- ~15-30 minutes per zone on L4 GPU

### dn-splatter
- Enhanced indoor reconstruction with depth + normal priors
- Best quality for LiDAR-captured zones
- ~30-60 minutes per zone

### 2dgs
- 2D Gaussian surfels (better planar surfaces)
- Can extract mesh after training
- ~30-45 minutes per zone

## Monitoring

Training progress is logged to stdout. Monitor with:
```bash
docker logs -f <container-id>
```

Key metrics:
- PSNR (>25 dB = good, >30 dB = excellent)
- SSIM (>0.85 = good, >0.90 = excellent)
- Splat count (target <1M for mobile)

## Cost Estimation (Cloud Run GPU)

- L4 GPU: ~$0.70/hour
- Typical zone training: 20-40 minutes
- Cost per zone: ~$0.25-$0.50

## Security

- Worker runs as non-root user (production TODO)
- Input/output via signed Cloud Storage URLs
- No persistent storage; all data in-memory during training

## Troubleshooting

### OOM (Out of Memory)
- Reduce `max_iterations` or `num_downscales`
- Use smaller batch size (not exposed in current config)
- Request more GPU memory (e.g., A100 instead of L4)

### Poor Quality
- Increase `max_iterations` to 50000
- Verify depth maps are valid (not all zeros)
- Check camera poses (ARKit coordinate system must match)

### Slow Training
- Use `splatfacto` instead of `dn-splatter`
- Reduce keyframe count in transforms.json
- Use faster GPU (A100, H100)

## Production Integration

The API should:
1. Trigger training after zone publish
2. Poll job status (or use webhook)
3. Download splat files to Firebase Storage
4. Update zone record with `gaussianSplatPath` and `gaussianSplatDataPath`
5. Notify clients that splat is available

See `../api/src/service.ts` for the `/trainSplat` endpoint.
