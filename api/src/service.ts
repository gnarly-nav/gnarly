import { randomBytes } from 'node:crypto';
import { assertAdmin } from './authz.ts';
import {
  ApiError,
  BUILDING_FILES,
  DOWNLOAD_TTL_MS,
  FILE_LIMITS,
  MAX_ZONES,
  PUBLISH_TTL_MS,
  TOTAL_LIMIT,
  UPLOAD_TTL_MS,
  ZONE_OPTIONAL,
  ZONE_REQUIRED,
  assertId,
  assertSize,
  contentTypeFor,
  defaultQuotas,
  objectPath,
  parseObjectPath,
  type Action,
  type BuildingRecord,
  type Caller,
  type CarryForward,
  type CommitWrite,
  type ExpectedFile,
  type FloorRecord,
  type PublishRecord,
  type PublishZone,
  type Quotas,
  type ZoneRecord,
} from './model.ts';
import { buildingData, parseRecordPath, rateKey, rateWindow, type CounterStore, type MetadataStore, type ObjectStore } from './store.ts';
import { validatePackageObject } from './validatePackage.ts';
import { type TexturingQueue } from './texturingQueue.ts';

export type Deps = {
  now: () => Date;
  adminUid: string;
  verifyToken: (token: string) => Promise<{ uid: string; email?: string; emailVerified?: boolean }>;
  objects: ObjectStore;
  metadata: MetadataStore;
  counters: CounterStore;
  texturingQueue?: TexturingQueue;
  quotas?: Quotas;
  uploadTtlMs?: number;
  downloadTtlMs?: number;
  publishTtlMs?: number;
};

type FileInput = { name?: unknown; size?: unknown; contentType?: unknown };

export class PublishApi {
  private readonly deps: Deps;
  private readonly quotas: Quotas;
  private readonly uploadTtlMs: number;
  private readonly downloadTtlMs: number;
  private readonly publishTtlMs: number;

  constructor(deps: Deps) {
    this.deps = deps;
    this.quotas = deps.quotas ?? defaultQuotas;
    this.uploadTtlMs = deps.uploadTtlMs ?? UPLOAD_TTL_MS;
    this.downloadTtlMs = deps.downloadTtlMs ?? DOWNLOAD_TTL_MS;
    this.publishTtlMs = deps.publishTtlMs ?? PUBLISH_TTL_MS;
  }

  async createBuilding(caller: Caller, body: unknown) {
    assertAdmin(caller);
    const input = objectBody(body);
    const id = assertId(stringField(input, 'id', 'buildingId'), 'buildingId');
    await this.limit('publish', caller, id);
    const name = bounded(stringField(input, 'name', 'name'), 'name', 120);
    const existing = await this.deps.metadata.getBuilding(id);
    if (existing) return { id, name: existing.name, created: false };
    const record: BuildingRecord = {
      id,
      name,
      status: 'draft',
      activeVersion: null,
      ownerUid: caller.uid,
      acl: { [caller.uid]: 'owner' },
      visibility: 'authenticated',
      ...placement(input),
    };
    await this.deps.metadata.createBuilding(record);
    return { id, name, created: true };
  }

  async listBuildings(caller: Caller) {
    await this.limit('list', caller, 'catalog');
    const buildings = [];
    for (const building of await this.deps.metadata.listBuildings()) {
      if (building.id === 'firebase-test') continue;
      const zones = building.activeVersion
        ? (await this.deps.metadata.listZones(building.id, building.activeVersion)).map(zone => ({
          id: zone.id,
          name: zone.name,
          floorId: zone.floorId,
        }))
        : [];
      buildings.push({
        id: building.id,
        name: building.name,
        status: building.status,
        activeVersion: building.activeVersion,
        latitude: building.latitude ?? null,
        longitude: building.longitude ?? null,
        mapHeadingDegrees: building.mapHeadingDegrees ?? null,
        metadataOnly: building.metadataOnly === true,
        zones,
      });
    }
    return { buildings };
  }

  async downloadPackage(caller: Caller, buildingId: string, query: URLSearchParams) {
    const id = assertId(buildingId, 'buildingId');
    await this.limit('download', caller, id);
    const building = await this.requireBuilding(id);
    const requestedVersion = query.get('version');
    const versionId = requestedVersion ? assertId(requestedVersion, 'versionId') : building.activeVersion;
    if (!versionId) throw new ApiError(404, 'not_published', 'This building has no active map version.');
    const version = await this.deps.metadata.getVersion(id, versionId);
    if (!version) throw new ApiError(404, 'not_found', 'That map version is not published.');
    const zoneFilter = query.get('zoneId');
    if (zoneFilter) assertId(zoneFilter, 'zoneId');
    const zones = (await this.deps.metadata.listZones(id, versionId)).filter(zone => !zoneFilter || zone.id === zoneFilter);
    if (zoneFilter && !zones.length) throw new ApiError(404, 'not_found', `Zone ${zoneFilter} is not in this map version.`);
    const expiresAt = new Date(this.deps.now().getTime() + this.downloadTtlMs);
    const lenient = building.metadataOnly === true;
    return {
      buildingId: id,
      versionId,
      name: building.name,
      metadataOnly: lenient,
      expiresAt: expiresAt.toISOString(),
      layoutRevision: version.webBuildingLayoutRevision ?? '',
      connectionsRevision: version.webZoneConnectionsRevision ?? '',
      graphRevision: version.webGraphRevision ?? '',
      files: await this.signVersionFiles(id, versionId, version, expiresAt, zones.length === 0),
      zones: await Promise.all(zones.map(zone => this.signZone(id, versionId, zone, expiresAt, lenient))),
    };
  }

  async signDownload(caller: Caller, body: unknown) {
    const path = stringField(objectBody(body), 'path', 'path').trim();
    const parsed = parseObjectPath(path);
    if (!parsed) throw new ApiError(400, 'invalid_path', 'That storage path is not a package file.');
    await this.limit('download', caller, parsed.buildingId);
    await this.requireBuilding(parsed.buildingId);
    const version = await this.deps.metadata.getVersion(parsed.buildingId, parsed.versionId);
    if (!version) throw new ApiError(404, 'not_found', 'That map version is not published.');
    const stat = await this.deps.objects.stat(path);
    if (!stat) throw new ApiError(404, 'not_found', 'That package file is not uploaded.');
    const expiresAt = new Date(this.deps.now().getTime() + this.downloadTtlMs);
    return {
      path,
      url: await this.deps.objects.signDownload(path, expiresAt),
      expiresAt: expiresAt.toISOString(),
    };
  }

  async startPublish(caller: Caller, buildingId: string, body: unknown) {
    assertAdmin(caller);
    const id = assertId(buildingId, 'buildingId');
    await this.limit('publish', caller, id);
    const building = await this.requireBuilding(id);
    const input = objectBody(body);
    const zones = this.parseZones(input.zones);
    const files = this.parseBuildingFiles(input.files);
    if (!zones.length && !files.length) throw new ApiError(400, 'invalid_package', 'A publish needs at least one zone or building file.');
    if (!zones.length && !building.activeVersion) {
      throw new ApiError(400, 'invalid_package', 'Upload a complete zone before publishing building files on their own.');
    }
    const total = [...zones.flatMap(zone => zone.files), ...files].reduce((sum, file) => sum + file.size, 0);
    if (total > TOTAL_LIMIT) throw new ApiError(413, 'too_large', `The package is ${total} bytes; the maximum is ${TOTAL_LIMIT}.`);

    const now = this.deps.now();
    const versionIds = new Set(await this.deps.metadata.listVersionIds(id));
    const publishes = await this.deps.metadata.listPublishes(id);
    const requested = optionalString(input.versionId);
    const reusable = this.reusableSession(publishes, caller.uid, requested, building.activeVersion, now);
    const versionId = reusable?.versionId ?? this.allocateVersion(requested, building.activeVersion, versionIds, publishes, now);
    const carry = await this.snapshot(id, building.activeVersion);
    const expected = [
      ...zones.flatMap(zone => zone.files.map(file => this.expected(id, versionId, file, zone.zoneId))),
      ...files.map(file => this.expected(id, versionId, file, '')),
    ];
    const record: PublishRecord = {
      id: reusable?.id ?? randomBytes(16).toString('hex'),
      buildingId: id,
      versionId,
      uid: caller.uid,
      status: 'open',
      expiresAt: new Date(now.getTime() + this.publishTtlMs).toISOString(),
      carriedFromVersion: building.activeVersion,
      files: expected,
      zones: zones.map(({ files: _files, ...zone }) => zone),
      carry,
    };
    await this.deps.metadata.savePublish(record);
    return this.signUploads(record);
  }

  async commitPublish(caller: Caller, buildingId: string, publishId: string) {
    assertAdmin(caller);
    const id = assertId(buildingId, 'buildingId');
    assertId(publishId, 'publishId');
    await this.limit('publish', caller, id);
    await this.requireBuilding(id);
    const publish = await this.deps.metadata.getPublish(id, publishId);
    if (!publish) throw new ApiError(404, 'not_found', 'That publish session does not exist.');
    if (publish.status === 'committed') {
      const current = await this.requireBuilding(id);
      return { buildingId: id, versionId: publish.versionId, activeVersion: current.activeVersion, committed: true };
    }
    if (Date.parse(publish.expiresAt) <= this.deps.now().getTime()) {
      throw new ApiError(409, 'publish_expired', 'The publish session expired before the package was checked. Start it again.');
    }

    for (const file of publish.files) {
      const stat = await this.deps.objects.stat(file.path);
      if (!stat) throw new ApiError(400, 'package_incomplete', `${file.path} has not been uploaded. The active map was not changed.`);
      if (stat.size !== file.size) {
        throw new ApiError(400, 'package_incomplete', `${file.name} is ${stat.size} bytes; the publish declared ${file.size}. The active map was not changed.`);
      }
      const bytes = await this.deps.objects.read(file.path, FILE_LIMITS[file.name] ?? file.size);
      validatePackageObject(file.name, bytes, file.zoneId);
    }

    const write = this.commitWrite(publish);
    await this.deps.metadata.commit(write);
    
    // Trigger texturing jobs for zones with mesh-bundle
    if (this.deps.texturingQueue) {
      for (const zone of publish.zones) {
        const hasMeshBundle = publish.files.some(file => file.zoneId === zone.zoneId && file.path.includes('mesh-bundle'));
        if (hasMeshBundle) {
          try {
            await this.deps.texturingQueue.enqueue(id, publish.versionId, zone.zoneId);
          } catch (error) {
            console.error(`[CommitPublish] Failed to enqueue texturing job for zone ${zone.zoneId}:`, error);
          }
        }
      }
    }
    
    return { buildingId: id, versionId: publish.versionId, activeVersion: publish.versionId, committed: true };
  }

  async buildingDetail(caller: Caller, buildingId: string) {
    const id = assertId(buildingId, 'buildingId');
    await this.limit('list', caller, id);
    const building = await this.requireBuilding(id);
    const versions = [];
    for (const versionId of await this.deps.metadata.listVersionIds(id)) {
      const version = await this.deps.metadata.getVersion(id, versionId);
      if (version) versions.push({ id: version.id, versionNumber: version.versionNumber, status: version.status });
    }
    versions.sort((a, b) => b.versionNumber - a.versionNumber);
    return {
      id: building.id,
      name: building.name,
      status: building.status,
      activeVersion: building.activeVersion,
      latitude: building.latitude ?? null,
      longitude: building.longitude ?? null,
      mapHeadingDegrees: building.mapHeadingDegrees ?? null,
      metadataOnly: building.metadataOnly === true,
      versions,
    };
  }

  async versionDetail(caller: Caller, buildingId: string, versionId: string) {
    const id = assertId(buildingId, 'buildingId');
    const versionKey = assertId(versionId, 'versionId');
    await this.limit('download', caller, id);
    await this.requireBuilding(id);
    const version = await this.deps.metadata.getVersion(id, versionKey);
    if (!version) throw new ApiError(404, 'not_found', 'That map version is not published.');
    return {
      buildingId: id,
      version,
      zones: await this.deps.metadata.listZones(id, versionKey),
      floors: await this.deps.metadata.listFloors(id, versionKey),
    };
  }

  async listRecords(caller: Caller) {
    await this.limit('list', caller, 'catalog');
    const records: { path: string; data: Record<string, unknown> }[] = [];
    for (const building of await this.deps.metadata.listBuildings()) {
      if (building.id === 'firebase-test') continue;
      records.push({ path: `buildings/${building.id}`, data: buildingData(building) });
      for (const versionId of await this.deps.metadata.listVersionIds(building.id)) {
        const version = await this.deps.metadata.getVersion(building.id, versionId);
        if (version) records.push({ path: `buildings/${building.id}/versions/${versionId}`, data: { ...version } });
        for (const zone of await this.deps.metadata.listZones(building.id, versionId)) {
          records.push({ path: `buildings/${building.id}/versions/${versionId}/zones/${zone.id}`, data: { ...zone } });
        }
        for (const floor of await this.deps.metadata.listFloors(building.id, versionId)) {
          records.push({ path: `buildings/${building.id}/versions/${versionId}/floors/${floor.id}`, data: { ...floor } });
        }
      }
      for (const publish of await this.deps.metadata.listPublishes(building.id)) {
        records.push({ path: `buildings/${building.id}/publishes/${publish.id}`, data: { ...publish } });
      }
    }
    records.sort((a, b) => a.path.localeCompare(b.path, undefined, { numeric: true }));
    return { records };
  }

  async saveRecord(caller: Caller, body: unknown) {
    assertAdmin(caller);
    const input = objectBody(body);
    const path = stringField(input, 'path', 'path').trim();
    if (!parseRecordPath(path)) throw new ApiError(400, 'invalid_path', 'That record path is not editable.');
    const before = objectBody(input.before);
    const after = objectBody(input.after);
    await this.limit('publish', caller, 'records');
    const result = await this.deps.metadata.patchRecord(path, before, after);
    if (result === 'missing') throw new ApiError(404, 'not_found', 'That record does not exist.');
    if (result === 'conflict') throw new ApiError(409, 'conflict', 'The record changed. Refresh before saving.');
    return { path, saved: true };
  }

  async signEditUpload(caller: Caller, body: unknown) {
    assertAdmin(caller);
    const input = objectBody(body);
    const path = stringField(input, 'path', 'path').trim();
    const parsed = parseObjectPath(path);
    if (!parsed) throw new ApiError(400, 'invalid_path', 'That storage path is not a package file.');
    await this.limit('publish', caller, parsed.buildingId);
    await this.requireBuilding(parsed.buildingId);
    const version = await this.deps.metadata.getVersion(parsed.buildingId, parsed.versionId);
    if (!version) throw new ApiError(404, 'not_found', 'That map version is not published.');
    const contentType = uploadContentType(path, input.contentType);
    const max = uploadLimit(path);
    const size = input.size;
    if (typeof size !== 'number' || !Number.isInteger(size) || size < 1 || size > max) {
      throw new ApiError(413, 'too_large', `That file must be between 1 and ${max} bytes.`);
    }
    const expiresAt = new Date(this.deps.now().getTime() + this.uploadTtlMs);
    return {
      path,
      method: 'PUT',
      url: await this.deps.objects.signUpload(path, contentType, expiresAt),
      headers: { 'Content-Type': contentType },
      expiresAt: expiresAt.toISOString(),
    };
  }

  async movePointer(caller: Caller, buildingId: string, body: unknown) {
    assertAdmin(caller);
    const id = assertId(buildingId, 'buildingId');
    await this.limit('publish', caller, id);
    const input = objectBody(body);
    const versionId = assertId(stringField(input, 'versionId', 'versionId'), 'versionId');
    const zoneId = optionalString(input.zoneId) ?? '';
    if (zoneId) assertId(zoneId, 'zoneId');
    const kind = stringField(input, 'kind', 'kind');
    const path = stringField(input, 'path', 'path').trim();
    const marker = bounded(stringField(input, 'marker', 'marker'), 'marker', 80);
    const expectedPath = typeof input.expectedPath === 'string' ? input.expectedPath : '';
    const expectedMarker = typeof input.expectedMarker === 'string' ? input.expectedMarker : '';
    const parsed = parseObjectPath(path);
    if (!parsed || parsed.buildingId !== id || parsed.versionId !== versionId) {
      throw new ApiError(400, 'invalid_path', 'That file is not in this map version.');
    }
    const fields = pointerFields(kind);
    if (kind === 'graph' && !path.includes('/graph-edits/') && !path.endsWith('/building.json')) {
      throw new ApiError(400, 'invalid_path', 'A graph edit must be stored as building.json.');
    }
    const version = await this.deps.metadata.getVersion(id, versionId);
    if (!version) throw new ApiError(404, 'not_found', 'That map version is not published.');
    const name = kind === 'graph' ? 'building.json' : kind === 'layout' ? 'building-layout.json' : 'zone-connections.json';
    const stat = await this.deps.objects.stat(path);
    if (!stat) throw new ApiError(400, 'missing_object', 'Upload the file before updating the pointer.');
    if (stat.size > FILE_LIMITS[name]) throw new ApiError(413, 'too_large', `${name} exceeds its size limit.`);
    const bytes = await this.deps.objects.read(path, FILE_LIMITS[name]);
    const zoneForSchema = name === 'building.json' && !zoneId ? zoneIdFromPackage(bytes) : zoneId;
    validatePackageObject(name, bytes, zoneForSchema);
    const result = await this.deps.metadata.updatePointer({
      buildingId: id,
      versionId,
      zoneId: kind === 'graph' ? zoneId : '',
      pathField: fields.path,
      markerField: fields.marker,
      path,
      marker,
      expectedPath,
      expectedMarker,
    });
    if (result === 'missing') throw new ApiError(404, 'not_found', 'That map record does not exist.');
    if (result === 'conflict') throw new ApiError(409, 'conflict', 'The map changed while you were editing. Reload before saving.');
    return { path, marker, updated: true };
  }

  private commitWrite(publish: PublishRecord): CommitWrite {
    const uploaded = new Map(publish.files.map(file => [`${file.zoneId}:${file.name}`, file.path]));
    const replaced = new Set(publish.zones.map(zone => zone.zoneId));
    const zones: ZoneRecord[] = publish.carry.zones.filter(zone => !replaced.has(zone.id)).map(zone => ({ ...zone }));
    for (const zone of publish.zones) {
      zones.push({
        id: zone.zoneId,
        name: zone.name,
        floorId: zone.floorId,
        relocalizationHint: zone.relocalizationHint,
        startNodeId: zone.startNodeId,
        buildingJsonPath: uploaded.get(`${zone.zoneId}:building.json`),
        scanJsonPath: uploaded.get(`${zone.zoneId}:scan.json`),
        scanFeaturesPath: uploaded.get(`${zone.zoneId}:scan-features.json`),
        structurePath: uploaded.get(`${zone.zoneId}:structure.usdz`),
        worldMapPath: uploaded.get(`${zone.zoneId}:worldmap.bin`),
        surfaceColorsPath: uploaded.get(`${zone.zoneId}:surface-colors.json`),
        surfaceColorAtlasPath: uploaded.get(`${zone.zoneId}:surface-colors.jpg`),
        texturedMeshPath: uploaded.get(`${zone.zoneId}:textured-mesh.glb`),
        texturedMeshMetadataPath: uploaded.get(`${zone.zoneId}:textured-mesh.json`),
      });
    }
    const floors = new Map(publish.carry.floors.map(floor => [floor.id, floor]));
    for (const zone of publish.zones) {
      floors.set(zone.floorId, { id: zone.floorId, name: zone.floorId, story: zone.story, elevation: zone.elevation });
    }
    return {
      buildingId: publish.buildingId,
      publishId: publish.id,
      versionId: publish.versionId,
      carriedFromVersion: publish.carriedFromVersion,
      version: {
        id: publish.versionId,
        versionNumber: this.deps.now().getTime(),
        status: 'published',
        publishId: publish.id,
        buildingLayoutPath: uploaded.get(':building-layout.json') ?? publish.carry.layoutPath,
        zoneConnectionsPath: uploaded.get(':zone-connections.json') ?? publish.carry.connectionsPath,
      },
      zones,
      floors: [...floors.values()],
    };
  }

  private async signUploads(record: PublishRecord) {
    const expiresAt = new Date(this.deps.now().getTime() + this.uploadTtlMs);
    const uploads = [];
    for (const file of record.files) {
      uploads.push({
        name: file.name,
        zoneId: file.zoneId,
        path: file.path,
        method: 'PUT',
        url: await this.deps.objects.signUpload(file.path, file.contentType, expiresAt),
        headers: { 'Content-Type': file.contentType },
        expiresAt: expiresAt.toISOString(),
      });
    }
    return {
      publishId: record.id,
      buildingId: record.buildingId,
      versionId: record.versionId,
      expiresAt: record.expiresAt,
      uploads,
    };
  }

  private async signZone(buildingId: string, versionId: string, zone: ZoneRecord, expiresAt: Date, lenient: boolean) {
    const files = [
      ['building.json', zone.buildingJsonPath, true],
      ['scan.json', zone.scanJsonPath, true],
      ['scan-features.json', zone.scanFeaturesPath, true],
      ['structure.usdz', zone.structurePath, true],
      ['worldmap.bin', zone.worldMapPath, true],
      ['surface-colors.json', zone.surfaceColorsPath, false],
      ['surface-colors.jpg', zone.surfaceColorAtlasPath, false],
      ['textured-mesh.glb', zone.texturedMeshPath, false],
      ['textured-mesh.json', zone.texturedMeshMetadataPath, false],
    ] as const;
    const signed = [];
    for (const [name, stored, required] of files) {
      const canonical = objectPath(buildingId, versionId, name, zone.id);
      const path = stored && parseObjectPath(stored)?.buildingId === buildingId ? stored : canonical;
      const stat = await this.deps.objects.stat(path);
      if (!stat) {
        if (required && !lenient) throw new ApiError(409, 'package_incomplete', `${path} is missing, so the package was not issued.`);
        continue;
      }
      signed.push({
        name,
        zoneId: zone.id,
        path,
        required,
        url: await this.deps.objects.signDownload(path, expiresAt),
        expiresAt: expiresAt.toISOString(),
      });
    }
    return { zoneId: zone.id, name: zone.name, floorId: zone.floorId, graphRevision: zone.webGraphRevision ?? '', files: signed };
  }

  private async signVersionFiles(buildingId: string, versionId: string, version: { buildingLayoutPath?: string | null; zoneConnectionsPath?: string | null; buildingJsonPath?: string | null; scanFeaturesPath?: string | null; structurePath?: string | null }, expiresAt: Date, legacy: boolean) {
    const files = [];
    const candidates: [string, string | null | undefined][] = [
      ['zone-connections.json', version.zoneConnectionsPath],
      ['building-layout.json', version.buildingLayoutPath],
    ];
    if (legacy) {
      candidates.push(
        ['building.json', version.buildingJsonPath],
        ['scan.json', null],
        ['scan-features.json', version.scanFeaturesPath],
        ['structure.usdz', version.structurePath],
      );
    }
    for (const [name, stored] of candidates) {
      const path = stored && parseObjectPath(stored)?.buildingId === buildingId ? stored : objectPath(buildingId, versionId, name);
      if (!(await this.deps.objects.stat(path))) continue;
      files.push({
        name,
        zoneId: '',
        path,
        required: false,
        url: await this.deps.objects.signDownload(path, expiresAt),
        expiresAt: expiresAt.toISOString(),
      });
    }
    return files;
  }

  private async snapshot(buildingId: string, versionId: string | null): Promise<CarryForward> {
    if (!versionId) return { zones: [], floors: [], layoutPath: null, connectionsPath: null };
    const version = await this.deps.metadata.getVersion(buildingId, versionId);
    return {
      zones: await this.deps.metadata.listZones(buildingId, versionId),
      floors: await this.deps.metadata.listFloors(buildingId, versionId),
      layoutPath: version?.buildingLayoutPath ?? null,
      connectionsPath: version?.zoneConnectionsPath ?? null,
    };
  }

  private allocateVersion(requested: string | undefined, active: string | null, existing: Set<string>, publishes: PublishRecord[], now: Date): string {
    if (requested && requested !== active) {
      assertId(requested, 'versionId');
      const reserved = publishes.some(item => item.versionId === requested && item.status === 'open' && Date.parse(item.expiresAt) > now.getTime());
      if (existing.has(requested) || reserved) {
        throw new ApiError(409, 'version_exists', 'That version already exists. Each publish stores a new immutable version.');
      }
      return requested;
    }
    return `v${now.getTime().toString(36)}${randomBytes(3).toString('hex')}`;
  }

  private reusableSession(publishes: PublishRecord[], uid: string, requested: string | undefined, active: string | null, now: Date) {
    return publishes
      .filter(item => item.uid === uid && item.status === 'open' && Date.parse(item.expiresAt) > now.getTime())
      .filter(item => requested && requested !== active ? item.versionId === requested : item.carriedFromVersion === active)
      .sort((a, b) => Date.parse(b.expiresAt) - Date.parse(a.expiresAt))[0];
  }

  private expected(buildingId: string, versionId: string, file: { name: string; size: number; contentType: string }, zoneId: string): ExpectedFile {
    return { name: file.name, zoneId, path: objectPath(buildingId, versionId, file.name, zoneId), size: file.size, contentType: file.contentType };
  }

  private parseZones(value: unknown): Array<PublishZone & { files: { name: string; size: number; contentType: string }[] }> {
    if (value == null) return [];
    if (!Array.isArray(value)) throw new ApiError(400, 'invalid_package', 'zones must be an array.');
    if (value.length > MAX_ZONES) throw new ApiError(400, 'invalid_package', `A publish can include at most ${MAX_ZONES} zones.`);
    const seen = new Set<string>();
    return value.map(item => {
      const zone = objectBody(item);
      const zoneId = assertId(stringField(zone, 'zoneId', 'zoneId'), 'zoneId');
      if (seen.has(zoneId)) throw new ApiError(400, 'invalid_package', `Zone ${zoneId} is listed twice.`);
      seen.add(zoneId);
      const names = new Set(this.parseFileList(zone.files, [...ZONE_REQUIRED, ...ZONE_OPTIONAL]).map(file => file.name));
      for (const name of ZONE_REQUIRED) {
        if (!names.has(name)) throw new ApiError(400, 'invalid_package', `Zone ${zoneId} is missing ${name}.`);
      }
      if (names.has('surface-colors.json') !== names.has('surface-colors.jpg')) {
        throw new ApiError(400, 'invalid_package', `Zone ${zoneId} must include surface-colors.json and surface-colors.jpg together.`);
      }
      const startNodeId = optionalString(zone.startNodeId) ?? '';
      if (startNodeId) assertId(startNodeId, 'startNodeId');
      return {
        zoneId,
        floorId: assertId(stringField(zone, 'floorId', 'floorId'), 'floorId'),
        name: bounded(stringField(zone, 'name', 'name'), 'zone name', 120),
        story: integerField(zone.story, 'story'),
        elevation: numberField(zone.elevation, 'elevation'),
        relocalizationHint: bounded(optionalString(zone.relocalizationHint) ?? 'Look around the scanned area.', 'relocalizationHint', 500),
        startNodeId,
        files: this.parseFileList(zone.files, [...ZONE_REQUIRED, ...ZONE_OPTIONAL]),
      };
    });
  }

  private parseBuildingFiles(value: unknown) {
    if (value == null) return [];
    return this.parseFileList(value, BUILDING_FILES);
  }

  private parseFileList(value: unknown, allowed: string[]) {
    if (!Array.isArray(value)) throw new ApiError(400, 'invalid_package', 'files must be an array.');
    const seen = new Set<string>();
    return value.map(item => {
      const file = objectBody(item) as FileInput;
      const name = stringField(file, 'name', 'file name');
      if (!allowed.includes(name)) throw new ApiError(400, 'invalid_file', `${name} is not a package file.`);
      if (seen.has(name)) throw new ApiError(400, 'invalid_file', `${name} is listed twice.`);
      seen.add(name);
      return { name, size: assertSize(name, file.size), contentType: contentTypeFor(name, file.contentType) };
    });
  }

  private async requireBuilding(id: string) {
    const building = await this.deps.metadata.getBuilding(id);
    if (!building) throw new ApiError(404, 'not_found', 'That building does not exist.');
    return building;
  }

  private async limit(action: Action, caller: Caller, buildingId: string) {
    // Viewing is public. Anonymous list/download calls were sharing one transaction
    // per IP and canceling each other. Only signed-in traffic, and every publish, is counted.
    if (caller.anonymous && action !== 'publish') return;
    const quota = this.quotas[action];
    const { windowStart, retryAfterSeconds } = rateWindow(quota, this.deps.now());
    const keys = (['user', 'building', 'ip'] as const).map(kind => ({
      id: rateKey(action, kind, kind === 'user' ? (caller.anonymous ? `anon:${caller.ip}` : caller.uid) : kind === 'ip' ? caller.ip : buildingId, windowStart),
      limit: quota[kind],
    })).sort((a, b) => a.id < b.id ? -1 : 1);
    const result = await this.deps.counters.consume(keys);
    if (!result.ok) {
      throw new ApiError(429, 'rate_limited', `Too many ${action} requests. Try again in ${retryAfterSeconds} seconds.`, { retryAfterSeconds });
    }
  }
}

function objectBody(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new ApiError(400, 'invalid_json', 'Expected a JSON object.');
  return value as Record<string, unknown>;
}

function stringField(body: Record<string, unknown> | FileInput, key: string, label: string): string {
  const value = (body as Record<string, unknown>)[key];
  if (typeof value !== 'string' || !value.trim()) throw new ApiError(400, 'invalid_json', `${label} is required.`);
  return value.trim();
}

function optionalString(value: unknown): string | undefined {
  if (value == null || value === '') return undefined;
  if (typeof value !== 'string') throw new ApiError(400, 'invalid_json', 'Expected a string.');
  return value.trim();
}

function bounded(value: string, label: string, max: number) {
  if (value.length > max) throw new ApiError(400, 'invalid_json', `${label} is too long.`);
  return value;
}

function integerField(value: unknown, label: string) {
  const number = value == null ? 0 : numberField(value, label);
  if (!Number.isInteger(number)) throw new ApiError(400, 'invalid_json', `${label} must be an integer.`);
  return number;
}

function numberField(value: unknown, label: string) {
  if (typeof value !== 'number' || !Number.isFinite(value)) throw new ApiError(400, 'invalid_json', `${label} must be a finite number.`);
  return value;
}

function placement(input: Record<string, unknown>) {
  const latitude = optionalNumber(input.latitude);
  const longitude = optionalNumber(input.longitude);
  const mapHeadingDegrees = optionalNumber(input.mapHeadingDegrees);
  return {
    ...(latitude == null ? {} : { latitude }),
    ...(longitude == null ? {} : { longitude }),
    ...(mapHeadingDegrees == null ? {} : { mapHeadingDegrees }),
  };
}

function optionalNumber(value: unknown) {
  if (value == null || value === '') return undefined;
  return numberField(value, 'coordinate');
}

function pointerFields(kind: string): { path: 'buildingJsonPath' | 'buildingLayoutPath' | 'zoneConnectionsPath'; marker: 'webGraphRevision' | 'webBuildingLayoutRevision' | 'webZoneConnectionsRevision' } {
  if (kind === 'graph') return { path: 'buildingJsonPath', marker: 'webGraphRevision' };
  if (kind === 'layout') return { path: 'buildingLayoutPath', marker: 'webBuildingLayoutRevision' };
  if (kind === 'connections') return { path: 'zoneConnectionsPath', marker: 'webZoneConnectionsRevision' };
  throw new ApiError(400, 'invalid_json', 'kind must be graph, layout, or connections.');
}

function uploadContentType(path: string, contentType: unknown) {
  if (path.includes('/graph-edits/')) {
    if (contentType !== 'application/json') throw new ApiError(400, 'invalid_file', 'Graph edits must use application/json.');
    return 'application/json';
  }
  return contentTypeFor(path.split('/').pop() || '', contentType);
}

function uploadLimit(path: string) {
  if (path.includes('/graph-edits/')) return FILE_LIMITS['building.json'];
  const name = path.split('/').pop() || '';
  const max = FILE_LIMITS[name];
  if (!max) throw new ApiError(400, 'invalid_file', `${name} is not a package file.`);
  return max;
}

function zoneIdFromPackage(bytes: Buffer) {
  try {
    const value = JSON.parse(bytes.toString('utf8')) as { zoneId?: unknown };
    return typeof value.zoneId === 'string' ? value.zoneId : '';
  } catch {
    return '';
  }
}
