/**
 * Texturing job queue for triggering the texturing-worker after zone publish.
 * 
 * In production, this would integrate with:
 * - Cloud Run Jobs for the texturing-worker container
 * - Pub/Sub for async job triggers
 * - Cloud Tasks for retry logic
 * 
 * For now, this provides the interface and a simple in-memory queue for testing.
 */

export type TexturingJob = {
  jobId: string;
  buildingId: string;
  versionId: string;
  zoneId: string;
  status: 'pending' | 'processing' | 'completed' | 'failed';
  createdAt: string;
  completedAt?: string;
  error?: string;
};

export interface TexturingQueue {
  /** Enqueue a new texturing job for a zone. Returns the job ID. */
  enqueue(buildingId: string, versionId: string, zoneId: string): Promise<string>;
  
  /** Get the status of a texturing job. */
  getJob(jobId: string): Promise<TexturingJob | null>;
  
  /** List all jobs for a building version. */
  listJobs(buildingId: string, versionId: string): Promise<TexturingJob[]>;
  
  /** Mark a job as completed and update the zone record with the textured mesh paths. */
  completeJob(jobId: string, texturedMeshPath: string, texturedMeshMetadataPath: string): Promise<void>;
  
  /** Mark a job as failed. */
  failJob(jobId: string, error: string): Promise<void>;
}

/**
 * In-memory implementation for testing. 
 * In production, replace with Cloud Tasks/Pub/Sub backend.
 */
export class MemoryTexturingQueue implements TexturingQueue {
  private jobs = new Map<string, TexturingJob>();
  
  async enqueue(buildingId: string, versionId: string, zoneId: string): Promise<string> {
    const jobId = `tex-${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;
    const job: TexturingJob = {
      jobId,
      buildingId,
      versionId,
      zoneId,
      status: 'pending',
      createdAt: new Date().toISOString(),
    };
    this.jobs.set(jobId, job);
    
    // In production, this would trigger the Cloud Run job:
    // await triggerCloudRunJob('gnarly-texturing-worker', { buildingId, versionId, zoneId, jobId });
    
    console.log(`[TexturingQueue] Enqueued job ${jobId} for zone ${zoneId}`);
    return jobId;
  }
  
  async getJob(jobId: string): Promise<TexturingJob | null> {
    return this.jobs.get(jobId) ?? null;
  }
  
  async listJobs(buildingId: string, versionId: string): Promise<TexturingJob[]> {
    return Array.from(this.jobs.values())
      .filter(job => job.buildingId === buildingId && job.versionId === versionId);
  }
  
  async completeJob(jobId: string, texturedMeshPath: string, texturedMeshMetadataPath: string): Promise<void> {
    const job = this.jobs.get(jobId);
    if (!job) throw new Error(`Job ${jobId} not found`);
    
    job.status = 'completed';
    job.completedAt = new Date().toISOString();
    
    // In production, this would update the zone record in Firestore/metadata store
    // to set texturedMeshPath and texturedMeshMetadataPath
    console.log(`[TexturingQueue] Job ${jobId} completed. Paths: ${texturedMeshPath}, ${texturedMeshMetadataPath}`);
  }
  
  async failJob(jobId: string, error: string): Promise<void> {
    const job = this.jobs.get(jobId);
    if (!job) throw new Error(`Job ${jobId} not found`);
    
    job.status = 'failed';
    job.completedAt = new Date().toISOString();
    job.error = error;
    
    console.error(`[TexturingQueue] Job ${jobId} failed: ${error}`);
  }
}

/**
 * Production implementation using Cloud Run Jobs + Pub/Sub.
 * 
 * Setup:
 * 1. Deploy texturing-worker as a Cloud Run Job
 * 2. Create a Pub/Sub topic for texturing requests
 * 3. Configure the job to be triggered by Pub/Sub messages
 * 4. Store job status in Firestore or Cloud Tasks
 * 
 * Usage:
 * - After committing a publish, call texturingQueue.enqueue(buildingId, versionId, zoneId)
 * - The worker processes the job and calls the API's /v1/texturing/complete endpoint
 * - The API updates the zone record with texturedMeshPath
 */
export function createProductionTexturingQueue(): TexturingQueue {
  // TODO: Implement with Google Cloud Pub/Sub + Cloud Run Jobs
  // For now, return the memory queue
  return new MemoryTexturingQueue();
}
