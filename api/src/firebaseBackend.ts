import { applicationDefault, getApps, initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { FieldValue, getFirestore, type DocumentData, type DocumentSnapshot, type Firestore } from 'firebase-admin/firestore';
import { getStorage } from 'firebase-admin/storage';
import {
  ApiError,
  type BuildingRecord,
  type CommitWrite,
  type FloorRecord,
  type PointerUpdate,
  type PublishRecord,
  type Role,
  type VersionRecord,
  type ZoneRecord,
} from './model.ts';
import { quotasFromEnv } from './quotas.ts';
import { canonical, parseRecordPath, type CounterStore, type MetadataStore, type ObjectStore, type RateKey } from './store.ts';
import type { Deps } from './service.ts';

const PROJECT_ID = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || 'gnarly-e65c1';
const BUCKET = process.env.FIREBASE_STORAGE_BUCKET || 'gnarly-e65c1.firebasestorage.app';

export function createFirebaseDeps(): Deps & { trustProxy?: boolean } {
  if (!getApps().length) {
    initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID, storageBucket: BUCKET });
  }
  const firestore = getFirestore();
  firestore.settings({ ignoreUndefinedProperties: true });
  const bucket = getStorage().bucket(BUCKET);
  const auth = getAuth();
  return {
    now: () => new Date(),
    adminUid: process.env.GNARLY_ADMIN_UID || 'WwvbXcl5hpQgdl8KO79JwcThYJd2',
    quotas: quotasFromEnv(),
    verifyToken: async token => {
      try {
        const decoded = await auth.verifyIdToken(token);
        return {
          uid: decoded.uid,
          email: typeof decoded.email === 'string' ? decoded.email : undefined,
          emailVerified: decoded.email_verified === true,
        };
      } catch {
        throw new ApiError(401, 'unauthenticated', 'Sign in again.');
      }
    },
    objects: new GcsObjectStore(bucket),
    metadata: new FirestoreMetadata(firestore),
    counters: new FirestoreCounters(firestore),
    trustProxy: true,
  };
}

class GcsObjectStore implements ObjectStore {
  private readonly bucket: ReturnType<ReturnType<typeof getStorage>['bucket']>;

  constructor(bucket: ReturnType<ReturnType<typeof getStorage>['bucket']>) {
    this.bucket = bucket;
  }

  private file(path: string) {
    return this.bucket.file(path);
  }

  async stat(path: string) {
    try {
      const [metadata] = await this.file(path).getMetadata();
      return { size: Number(metadata.size || 0), contentType: metadata.contentType };
    } catch (error) {
      if (isNotFound(error)) return null;
      throw error;
    }
  }

  async read(path: string, maxBytes: number) {
    const stat = await this.stat(path);
    if (!stat) throw new ApiError(404, 'missing_object', `${path} has not been uploaded.`);
    if (stat.size > maxBytes) throw new ApiError(413, 'too_large', `${path} exceeds its size limit.`);
    const [bytes] = await this.file(path).download();
    return bytes;
  }

  async signUpload(path: string, contentType: string, expiresAt: Date) {
    const [url] = await this.file(path).getSignedUrl({ version: 'v4', action: 'write', expires: expiresAt, contentType });
    return url;
  }

  async signDownload(path: string, expiresAt: Date) {
    const [url] = await this.file(path).getSignedUrl({ version: 'v4', action: 'read', expires: expiresAt });
    return url;
  }
}

class FirestoreMetadata implements MetadataStore {
  private readonly db: Firestore;

  constructor(db: Firestore) {
    this.db = db;
  }

  private building(id: string) {
    return this.db.collection('buildings').doc(id);
  }

  async getBuilding(id: string) {
    const snap = await this.building(id).get();
    return snap.exists ? mapBuilding(id, snap.data() || {}) : null;
  }

  async createBuilding(record: BuildingRecord) {
    const ref = this.building(record.id);
    return this.db.runTransaction(async tx => {
      const snap = await tx.get(ref);
      if (snap.exists) return 'exists' as const;
      tx.set(ref, {
        name: record.name,
        activeVersion: null,
        status: 'draft',
        ownerUid: record.ownerUid,
        acl: record.acl,
        visibility: record.visibility,
        ...numberFields(record),
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      return 'created' as const;
    });
  }

  async listBuildings() {
    const snap = await this.db.collection('buildings').get();
    return snap.docs.map(doc => mapBuilding(doc.id, doc.data()));
  }

  async getVersion(buildingId: string, versionId: string) {
    const snap = await this.building(buildingId).collection('versions').doc(versionId).get();
    return snap.exists ? mapVersion(versionId, snap.data() || {}) : null;
  }

  async listVersionIds(buildingId: string) {
    const snap = await this.building(buildingId).collection('versions').get();
    return snap.docs.map(doc => doc.id);
  }

  async listZones(buildingId: string, versionId: string) {
    const snap = await this.building(buildingId).collection('versions').doc(versionId).collection('zones').get();
    return snap.docs.map(doc => mapZone(doc.id, doc.data()));
  }

  async listFloors(buildingId: string, versionId: string) {
    const snap = await this.building(buildingId).collection('versions').doc(versionId).collection('floors').get();
    return snap.docs.map(doc => mapFloor(doc.id, doc.data()));
  }

  async listPublishes(buildingId: string) {
    const snap = await this.building(buildingId).collection('publishes').get();
    return snap.docs.map(doc => doc.data() as PublishRecord);
  }

  async savePublish(record: PublishRecord) {
    await this.building(record.buildingId).collection('publishes').doc(record.id).set(record);
  }

  async getPublish(buildingId: string, publishId: string) {
    const snap = await this.building(buildingId).collection('publishes').doc(publishId).get();
    return snap.exists ? snap.data() as PublishRecord : null;
  }

  async commit(write: CommitWrite) {
    const buildingRef = this.building(write.buildingId);
    const publishRef = buildingRef.collection('publishes').doc(write.publishId);
    const versionRef = buildingRef.collection('versions').doc(write.versionId);
    return this.db.runTransaction(async tx => {
      const buildingSnap = await tx.get(buildingRef);
      const publishSnap = await tx.get(publishRef);
      if (!publishSnap.exists) throw new ApiError(404, 'not_found', 'That publish session does not exist.');
      const publish = publishSnap.data() as PublishRecord;
      if (publish.status === 'committed') return 'already' as const;
      if (Date.parse(publish.expiresAt) <= Date.now()) {
        throw new ApiError(409, 'publish_expired', 'The publish session expired before the package was checked. Start it again.');
      }
      const active = buildingSnap.get('activeVersion') || null;
      if ((active || null) !== (write.carriedFromVersion || null)) {
        throw new ApiError(409, 'building_changed', 'The building changed while the package uploaded. Publish it again.');
      }
      tx.set(versionRef, defined({
        versionNumber: write.version.versionNumber,
        status: 'published',
        publishId: write.publishId,
        buildingLayoutPath: write.version.buildingLayoutPath ?? null,
        zoneConnectionsPath: write.version.zoneConnectionsPath ?? null,
        createdAt: FieldValue.serverTimestamp(),
        publishedAt: FieldValue.serverTimestamp(),
      }));
      for (const zone of write.zones) {
        tx.set(versionRef.collection('zones').doc(zone.id), defined({
          name: zone.name,
          floorId: zone.floorId,
          worldMapPath: zone.worldMapPath,
          buildingJsonPath: zone.buildingJsonPath,
          scanJsonPath: zone.scanJsonPath,
          scanFeaturesPath: zone.scanFeaturesPath,
          structurePath: zone.structurePath,
          surfaceColorsPath: zone.surfaceColorsPath,
          surfaceColorAtlasPath: zone.surfaceColorAtlasPath,
          texturedMeshPath: zone.texturedMeshPath,
          texturedMeshMetadataPath: zone.texturedMeshMetadataPath,
          relocalizationHint: zone.relocalizationHint ?? '',
          startNodeId: zone.startNodeId ?? '',
        }));
      }
      for (const floor of write.floors) {
        tx.set(versionRef.collection('floors').doc(floor.id), {
          name: floor.name,
          story: floor.story,
          elevation: floor.elevation,
        });
      }
      tx.update(buildingRef, {
        activeVersion: write.versionId,
        status: 'active',
        updatedAt: FieldValue.serverTimestamp(),
      });
      tx.update(publishRef, { status: 'committed', committedAt: new Date().toISOString() });
      return 'committed' as const;
    });
  }

  async updatePointer(update: PointerUpdate) {
    const ref = update.zoneId
      ? this.building(update.buildingId).collection('versions').doc(update.versionId).collection('zones').doc(update.zoneId)
      : this.building(update.buildingId).collection('versions').doc(update.versionId);
    return this.db.runTransaction(async tx => {
      const snap = await tx.get(ref);
      if (!snap.exists) return 'missing' as const;
      const path = snap.get(update.pathField) ? String(snap.get(update.pathField)) : '';
      const marker = snap.get(update.markerField) ? String(snap.get(update.markerField)) : '';
      if (path !== update.expectedPath || marker !== update.expectedMarker) return 'conflict' as const;
      tx.update(ref, { [update.pathField]: update.path, [update.markerField]: update.marker });
      return 'updated' as const;
    });
  }

  async patchRecord(path: string, before: Record<string, unknown>, after: Record<string, unknown>) {
    const ref = recordRef(this.db, path);
    if (!ref) return 'missing' as const;
    return this.db.runTransaction(async tx => {
      const snap = await tx.get(ref);
      if (!snap.exists) return 'missing' as const;
      const current = plain(snap.data() || {}) as Record<string, unknown>;
      if (canonical(current) !== canonical(before)) return 'conflict' as const;
      const patch: Record<string, unknown> = {};
      for (const [key, value] of Object.entries(after)) {
        if (canonical(value) !== canonical(current[key])) patch[key] = value;
      }
      for (const key of Object.keys(current)) {
        if (!(key in after)) patch[key] = FieldValue.delete();
      }
      if (Object.keys(patch).length) tx.update(ref, patch as DocumentData);
      return 'saved' as const;
    });
  }
}

class FirestoreCounters implements CounterStore {
  private readonly db: Firestore;

  constructor(db: Firestore) {
    this.db = db;
  }

  async consume(keys: RateKey[]) {
    const ordered = [...keys].sort((a, b) => a.id < b.id ? -1 : 1);
    const refs = ordered.map(key => this.db.collection('rateLimits').doc(key.id));
    return this.db.runTransaction(async tx => {
      const snaps: DocumentSnapshot[] = [];
      for (const ref of refs) snaps.push(await tx.get(ref));
      for (let index = 0; index < ordered.length; index += 1) {
        const count = snaps[index].exists ? Number(snaps[index].get('count') || 0) : 0;
        if (count >= ordered[index].limit) return { ok: false as const };
      }
      ordered.forEach((key, index) => {
        const count = snaps[index].exists ? Number(snaps[index].get('count') || 0) : 0;
        tx.set(refs[index], { count: count + 1, expiresAt: new Date(Date.now() + 2 * 60 * 60 * 1000) });
      });
      return { ok: true as const };
    });
  }
}

function mapBuilding(id: string, data: DocumentData): BuildingRecord {
  const acl: Record<string, Role> = {};
  if (data.acl && typeof data.acl === 'object') {
    for (const [uid, role] of Object.entries(data.acl as Record<string, unknown>)) {
      if (role === 'owner' || role === 'editor' || role === 'viewer') acl[uid] = role;
    }
  }
  return {
    id,
    name: String(data.name || id),
    status: String(data.status || 'draft'),
    activeVersion: data.activeVersion ? String(data.activeVersion) : null,
    ownerUid: data.ownerUid ? String(data.ownerUid) : null,
    acl,
    visibility: data.visibility === 'members' ? 'members' : 'authenticated',
    ...(typeof data.latitude === 'number' ? { latitude: data.latitude } : {}),
    ...(typeof data.longitude === 'number' ? { longitude: data.longitude } : {}),
    ...(typeof data.mapHeadingDegrees === 'number' ? { mapHeadingDegrees: data.mapHeadingDegrees } : {}),
  };
}

function mapVersion(id: string, data: DocumentData): VersionRecord {
  return {
    id,
    versionNumber: Number(data.versionNumber || 0),
    status: String(data.status || 'draft'),
    buildingLayoutPath: data.buildingLayoutPath ? String(data.buildingLayoutPath) : null,
    zoneConnectionsPath: data.zoneConnectionsPath ? String(data.zoneConnectionsPath) : null,
    buildingJsonPath: data.buildingJsonPath ? String(data.buildingJsonPath) : null,
    scanFeaturesPath: data.scanFeaturesPath ? String(data.scanFeaturesPath) : null,
    structurePath: data.structurePath ? String(data.structurePath) : null,
    publishId: data.publishId ? String(data.publishId) : undefined,
    ...(data.webGraphRevision ? { webGraphRevision: String(data.webGraphRevision) } : {}),
    ...(data.webBuildingLayoutRevision ? { webBuildingLayoutRevision: String(data.webBuildingLayoutRevision) } : {}),
    ...(data.webZoneConnectionsRevision ? { webZoneConnectionsRevision: String(data.webZoneConnectionsRevision) } : {}),
  };
}

function mapZone(id: string, data: DocumentData): ZoneRecord {
  const text = (field: string) => (data[field] ? String(data[field]) : undefined);
  return {
    id,
    name: String(data.name || id),
    floorId: String(data.floorId || 'ground'),
    worldMapPath: text('worldMapPath'),
    buildingJsonPath: text('buildingJsonPath'),
    scanJsonPath: text('scanJsonPath'),
    scanFeaturesPath: text('scanFeaturesPath'),
    structurePath: text('structurePath'),
    surfaceColorsPath: text('surfaceColorsPath'),
    surfaceColorAtlasPath: text('surfaceColorAtlasPath'),
    texturedMeshPath: text('texturedMeshPath'),
    texturedMeshMetadataPath: text('texturedMeshMetadataPath'),
    relocalizationHint: text('relocalizationHint'),
    startNodeId: text('startNodeId'),
    webGraphRevision: text('webGraphRevision'),
  };
}

function mapFloor(id: string, data: DocumentData): FloorRecord {
  return { id, name: String(data.name || id), story: Number(data.story || 0), elevation: Number(data.elevation || 0) };
}

function defined(value: Record<string, unknown>) {
  return Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined));
}

function numberFields(record: BuildingRecord) {
  return {
    ...(record.latitude == null ? {} : { latitude: record.latitude }),
    ...(record.longitude == null ? {} : { longitude: record.longitude }),
    ...(record.mapHeadingDegrees == null ? {} : { mapHeadingDegrees: record.mapHeadingDegrees }),
  };
}

function isNotFound(error: unknown) {
  return typeof error === 'object' && error !== null && 'code' in error && (error as { code?: number }).code === 404;
}

function recordRef(db: Firestore, path: string) {
  const parsed = parseRecordPath(path);
  if (!parsed) return null;
  const building = db.collection('buildings').doc(parsed.buildingId);
  if (parsed.kind === 'building') return building;
  if (parsed.kind === 'publish') return building.collection('publishes').doc(parsed.publishId);
  const version = building.collection('versions').doc(parsed.versionId);
  if (parsed.kind === 'version') return version;
  if (parsed.kind === 'zone') return version.collection('zones').doc(parsed.zoneId);
  return version.collection('floors').doc(parsed.floorId);
}

function plain(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(plain);
  if (value && typeof value === 'object') {
    if ('toDate' in value && typeof (value as { toDate?: unknown }).toDate === 'function') {
      return (value as { toDate: () => Date }).toDate().toISOString();
    }
    const entries = Object.entries(value as Record<string, unknown>);
    if (entries.length === 2 && entries.every(([key]) => key === 'latitude' || key === 'longitude')) {
      return Object.fromEntries(entries);
    }
    return Object.fromEntries(entries.map(([key, item]) => [key, plain(item)]));
  }
  return value;
}
