import { createHash } from 'node:crypto';
import {
  ApiError,
  type Action,
  type BuildingRecord,
  type CommitWrite,
  type FloorRecord,
  type PointerUpdate,
  type PublishRecord,
  type Quota,
  type VersionRecord,
  type ZoneRecord,
} from './model.ts';

export type SignedUrl = { url: string; expiresAt: string };

export interface ObjectStore {
  stat(path: string): Promise<{ size: number; contentType?: string } | null>;
  read(path: string, maxBytes: number): Promise<Buffer>;
  signUpload(path: string, contentType: string, expiresAt: Date): Promise<string>;
  signDownload(path: string, expiresAt: Date): Promise<string>;
}

export interface MetadataStore {
  getBuilding(id: string): Promise<BuildingRecord | null>;
  createBuilding(record: BuildingRecord): Promise<'created' | 'exists'>;
  listBuildings(): Promise<BuildingRecord[]>;
  getVersion(buildingId: string, versionId: string): Promise<VersionRecord | null>;
  listVersionIds(buildingId: string): Promise<string[]>;
  listZones(buildingId: string, versionId: string): Promise<ZoneRecord[]>;
  listFloors(buildingId: string, versionId: string): Promise<FloorRecord[]>;
  listPublishes(buildingId: string): Promise<PublishRecord[]>;
  savePublish(record: PublishRecord): Promise<void>;
  getPublish(buildingId: string, publishId: string): Promise<PublishRecord | null>;
  commit(write: CommitWrite): Promise<'committed' | 'already'>;
  /** Move a JSON pointer only when the caller still sees the same path and revision. */
  updatePointer(update: PointerUpdate): Promise<'updated' | 'conflict' | 'missing'>;
  /** Replace one metadata document when `before` still matches what is stored. */
  patchRecord(path: string, before: Record<string, unknown>, after: Record<string, unknown>): Promise<'saved' | 'conflict' | 'missing'>;
}

export type RateKey = { id: string; limit: number };

export interface CounterStore {
  consume(keys: RateKey[]): Promise<{ ok: true } | { ok: false }>;
}

export function rateWindow(quota: Quota, now: Date) {
  const windowStart = Math.floor(now.getTime() / quota.windowMs) * quota.windowMs;
  const retryAfterSeconds = Math.max(1, Math.ceil((windowStart + quota.windowMs - now.getTime()) / 1000));
  return { windowStart, retryAfterSeconds };
}

export function rateKey(action: Action, kind: 'user' | 'building' | 'ip', id: string, windowStart: number): string {
  const hash = createHash('sha256').update(`${id}:${windowStart}`).digest('hex').slice(0, 32);
  return `${action}_${kind}_${hash}`;
}

export class MemoryObjectStore implements ObjectStore {
  readonly objects = new Map<string, { bytes: Buffer; contentType: string }>();

  async stat(path: string) {
    const item = this.objects.get(path);
    return item ? { size: item.bytes.length, contentType: item.contentType } : null;
  }

  async read(path: string, maxBytes: number) {
    const item = this.objects.get(path);
    if (!item) throw new ApiError(404, 'missing_object', `${path} has not been uploaded.`);
    if (item.bytes.length > maxBytes) throw new ApiError(413, 'too_large', `${path} exceeds its size limit.`);
    return item.bytes;
  }

  async signUpload(path: string, contentType: string, expiresAt: Date) {
    return `https://signed.example/upload?path=${encodeURIComponent(path)}&exp=${expiresAt.getTime()}&type=${encodeURIComponent(contentType)}`;
  }

  async signDownload(path: string, expiresAt: Date) {
    return `https://signed.example/download?path=${encodeURIComponent(path)}&exp=${expiresAt.getTime()}`;
  }

  put(path: string, bytes: Buffer, contentType: string) {
    this.objects.set(path, { bytes, contentType });
  }
}

export class MemoryMetadata implements MetadataStore {
  readonly buildings = new Map<string, BuildingRecord>();
  readonly versions = new Map<string, VersionRecord>();
  readonly zones = new Map<string, ZoneRecord[]>();
  readonly floors = new Map<string, FloorRecord[]>();
  readonly publishes = new Map<string, PublishRecord>();

  private versionKey(buildingId: string, versionId: string) {
    return `${buildingId}/${versionId}`;
  }

  async getBuilding(id: string) {
    return this.buildings.get(id) ?? null;
  }

  async createBuilding(record: BuildingRecord) {
    if (this.buildings.has(record.id)) return 'exists';
    this.buildings.set(record.id, record);
    return 'created';
  }

  async listBuildings() {
    return [...this.buildings.values()];
  }

  async getVersion(buildingId: string, versionId: string) {
    return this.versions.get(this.versionKey(buildingId, versionId)) ?? null;
  }

  async listVersionIds(buildingId: string) {
    const prefix = `${buildingId}/`;
    return [...this.versions.keys()].filter(key => key.startsWith(prefix)).map(key => key.slice(prefix.length));
  }

  async listZones(buildingId: string, versionId: string) {
    return this.zones.get(this.versionKey(buildingId, versionId)) ?? [];
  }

  async listFloors(buildingId: string, versionId: string) {
    return this.floors.get(this.versionKey(buildingId, versionId)) ?? [];
  }

  async listPublishes(buildingId: string) {
    return [...this.publishes.values()].filter(item => item.buildingId === buildingId);
  }

  async savePublish(record: PublishRecord) {
    this.publishes.set(`${record.buildingId}/${record.id}`, record);
  }

  async getPublish(buildingId: string, publishId: string) {
    return this.publishes.get(`${buildingId}/${publishId}`) ?? null;
  }

  async commit(write: CommitWrite) {
    const publish = await this.getPublish(write.buildingId, write.publishId);
    if (!publish) throw new ApiError(404, 'not_found', 'That publish session does not exist.');
    if (publish.status === 'committed') return 'already';
    const building = this.buildings.get(write.buildingId);
    if (!building) throw new ApiError(404, 'not_found', 'That building does not exist.');
    if ((building.activeVersion ?? null) !== (write.carriedFromVersion ?? null)) {
      throw new ApiError(409, 'building_changed', 'The building changed while the package uploaded. Publish it again.');
    }
    const key = this.versionKey(write.buildingId, write.versionId);
    this.versions.set(key, write.version);
    this.zones.set(key, write.zones.map(zone => ({ ...zone })));
    this.floors.set(key, write.floors.map(floor => ({ ...floor })));
    building.activeVersion = write.versionId;
    building.status = 'active';
    publish.status = 'committed';
    return 'committed';
  }

  async updatePointer(update: PointerUpdate) {
    const target = this.pointerTarget(update);
    if (!target) return 'missing';
    const path = stringOrEmpty(target[update.pathField]);
    const marker = stringOrEmpty(target[update.markerField]);
    if (path !== update.expectedPath || marker !== update.expectedMarker) return 'conflict';
    target[update.pathField] = update.path;
    target[update.markerField] = update.marker;
    return 'updated';
  }

  async patchRecord(path: string, before: Record<string, unknown>, after: Record<string, unknown>) {
    const current = this.recordData(path);
    if (!current) return 'missing';
    if (canonical(current) !== canonical(before)) return 'conflict';
    const ref = parseRecordPath(path);
    if (!ref) return 'missing';
    if (ref.kind === 'building') {
      const building = this.buildings.get(ref.buildingId);
      if (!building) return 'missing';
      applyBuilding(building, after);
      return 'saved';
    }
    if (ref.kind === 'version') {
      const version = this.versions.get(this.versionKey(ref.buildingId, ref.versionId));
      if (!version) return 'missing';
      applyVersion(version, after);
      return 'saved';
    }
    if (ref.kind === 'zone') {
      const zones = this.zones.get(this.versionKey(ref.buildingId, ref.versionId));
      const zone = zones?.find(item => item.id === ref.zoneId);
      if (!zone) return 'missing';
      applyZone(zone, after);
      return 'saved';
    }
    if (ref.kind === 'floor') {
      const floors = this.floors.get(this.versionKey(ref.buildingId, ref.versionId));
      const floor = floors?.find(item => item.id === ref.floorId);
      if (!floor) return 'missing';
      if (typeof after.name === 'string') floor.name = after.name;
      if (typeof after.story === 'number') floor.story = after.story;
      if (typeof after.elevation === 'number') floor.elevation = after.elevation;
      return 'saved';
    }
    const publish = this.publishes.get(`${ref.buildingId}/${ref.publishId}`);
    if (!publish) return 'missing';
    if (after.status === 'open' || after.status === 'committed') publish.status = after.status;
    if (typeof after.expiresAt === 'string') publish.expiresAt = after.expiresAt;
    return 'saved';
  }

  recordData(path: string): Record<string, unknown> | null {
    const ref = parseRecordPath(path);
    if (!ref) return null;
    if (ref.kind === 'building') {
      const building = this.buildings.get(ref.buildingId);
      return building ? buildingData(building) : null;
    }
    if (ref.kind === 'version') {
      const version = this.versions.get(this.versionKey(ref.buildingId, ref.versionId));
      return version ? { ...version } : null;
    }
    if (ref.kind === 'zone') {
      const zone = this.zones.get(this.versionKey(ref.buildingId, ref.versionId))?.find(item => item.id === ref.zoneId);
      return zone ? { ...zone } : null;
    }
    if (ref.kind === 'floor') {
      const floor = this.floors.get(this.versionKey(ref.buildingId, ref.versionId))?.find(item => item.id === ref.floorId);
      return floor ? { ...floor } : null;
    }
    const publish = this.publishes.get(`${ref.buildingId}/${ref.publishId}`);
    return publish ? { ...publish } : null;
  }

  private pointerTarget(update: PointerUpdate): Record<string, unknown> | null {
    if (update.zoneId) {
      const zone = this.zones.get(this.versionKey(update.buildingId, update.versionId))?.find(item => item.id === update.zoneId);
      return zone ? zone as unknown as Record<string, unknown> : null;
    }
    const version = this.versions.get(this.versionKey(update.buildingId, update.versionId));
    return version ? version as unknown as Record<string, unknown> : null;
  }
}

export type RecordRef =
  | { kind: 'building'; buildingId: string }
  | { kind: 'version'; buildingId: string; versionId: string }
  | { kind: 'zone'; buildingId: string; versionId: string; zoneId: string }
  | { kind: 'floor'; buildingId: string; versionId: string; floorId: string }
  | { kind: 'publish'; buildingId: string; publishId: string };

export function parseRecordPath(path: string): RecordRef | null {
  const parts = path.split('/');
  if (parts[0] !== 'buildings' || parts.length < 2) return null;
  const buildingId = parts[1];
  if (!buildingId) return null;
  if (parts.length === 2) return { kind: 'building', buildingId };
  if (parts[2] === 'versions' && parts.length === 4) return { kind: 'version', buildingId, versionId: parts[3] };
  if (parts[2] === 'versions' && parts[4] === 'zones' && parts.length === 6) {
    return { kind: 'zone', buildingId, versionId: parts[3], zoneId: parts[5] };
  }
  if (parts[2] === 'versions' && parts[4] === 'floors' && parts.length === 6) {
    return { kind: 'floor', buildingId, versionId: parts[3], floorId: parts[5] };
  }
  if (parts[2] === 'publishes' && parts.length === 4) return { kind: 'publish', buildingId, publishId: parts[3] };
  return null;
}

export function canonical(value: unknown): string {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (value && typeof value === 'object') {
    return '{' + Object.entries(value as Record<string, unknown>).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => JSON.stringify(key) + ':' + canonical(item)).join(',') + '}';
  }
  return JSON.stringify(value);
}

export function buildingData(building: BuildingRecord): Record<string, unknown> {
  return {
    name: building.name,
    status: building.status,
    activeVersion: building.activeVersion,
    ownerUid: building.ownerUid,
    legacyOwnerUid: building.legacyOwnerUid ?? null,
    acl: building.acl,
    visibility: building.visibility,
    ...(building.latitude == null ? {} : { latitude: building.latitude }),
    ...(building.longitude == null ? {} : { longitude: building.longitude }),
    ...(building.mapHeadingDegrees == null ? {} : { mapHeadingDegrees: building.mapHeadingDegrees }),
    ...(building.metadataOnly ? { metadataOnly: true } : {}),
  };
}

function stringOrEmpty(value: unknown) {
  return typeof value === 'string' ? value : '';
}

function applyBuilding(building: BuildingRecord, after: Record<string, unknown>) {
  if (typeof after.name === 'string') building.name = after.name;
  if (typeof after.status === 'string') building.status = after.status;
  if (after.activeVersion === null || typeof after.activeVersion === 'string') building.activeVersion = after.activeVersion;
  if (after.ownerUid === null || typeof after.ownerUid === 'string') building.ownerUid = after.ownerUid;
  if (after.legacyOwnerUid === null || typeof after.legacyOwnerUid === 'string') building.legacyOwnerUid = after.legacyOwnerUid;
  if (after.visibility === 'members' || after.visibility === 'authenticated') building.visibility = after.visibility;
  if (typeof after.metadataOnly === 'boolean') building.metadataOnly = after.metadataOnly;
  if (typeof after.latitude === 'number') building.latitude = after.latitude;
  if (typeof after.longitude === 'number') building.longitude = after.longitude;
  if (typeof after.mapHeadingDegrees === 'number') building.mapHeadingDegrees = after.mapHeadingDegrees;
  if (after.acl && typeof after.acl === 'object' && !Array.isArray(after.acl)) {
    building.acl = {};
    for (const [uid, role] of Object.entries(after.acl as Record<string, unknown>)) {
      if (role === 'owner' || role === 'editor' || role === 'viewer') building.acl[uid] = role;
    }
  }
}

function applyVersion(version: VersionRecord, after: Record<string, unknown>) {
  if (typeof after.status === 'string') version.status = after.status;
  if (typeof after.versionNumber === 'number') version.versionNumber = after.versionNumber;
  for (const field of ['buildingLayoutPath', 'zoneConnectionsPath', 'buildingJsonPath', 'scanFeaturesPath', 'structurePath'] as const) {
    if (after[field] === null || typeof after[field] === 'string') version[field] = after[field] as string | null;
  }
  for (const field of ['webGraphRevision', 'webBuildingLayoutRevision', 'webZoneConnectionsRevision'] as const) {
    if (typeof after[field] === 'string') version[field] = after[field] as string;
  }
}

function applyZone(zone: ZoneRecord, after: Record<string, unknown>) {
  if (typeof after.name === 'string') zone.name = after.name;
  if (typeof after.floorId === 'string') zone.floorId = after.floorId;
  for (const field of ['worldMapPath', 'buildingJsonPath', 'scanJsonPath', 'scanFeaturesPath', 'structurePath', 'surfaceColorsPath', 'surfaceColorAtlasPath', 'texturedMeshPath', 'texturedMeshMetadataPath', 'relocalizationHint', 'startNodeId', 'webGraphRevision'] as const) {
    if (typeof after[field] === 'string') zone[field] = after[field] as string;
  }
}

export class MemoryCounters implements CounterStore {
  readonly counts = new Map<string, number>();

  async consume(keys: RateKey[]) {
    for (const key of keys) {
      if ((this.counts.get(key.id) ?? 0) >= key.limit) return { ok: false as const };
    }
    for (const key of keys) this.counts.set(key.id, (this.counts.get(key.id) ?? 0) + 1);
    return { ok: true as const };
  }
}
