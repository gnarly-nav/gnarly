import { DynamoDBDocumentClient, GetCommand, PutCommand, QueryCommand, TransactWriteCommand, UpdateCommand } from '@aws-sdk/lib-dynamodb';
import { ApiError, type BuildingRecord, type CommitWrite, type FloorRecord, type PointerUpdate, type PublishRecord, type Role, type VersionRecord, type ZoneRecord } from './model.ts';
import { buildingData, canonical, parseRecordPath, type CounterStore, type MetadataStore, type RateKey } from './store.ts';

const BUILDINGS = 'BUILDINGS';

export function buildingPk(id: string) {
  return `BUILDING#${id}`;
}

export function versionSk(versionId: string) {
  return `VERSION#${versionId}`;
}

export function zoneSk(versionId: string, zoneId: string) {
  return `ZONE#${versionId}#${zoneId}`;
}

export function floorSk(versionId: string, floorId: string) {
  return `FLOOR#${versionId}#${floorId}`;
}

export function publishSk(publishId: string) {
  return `PUBLISH#${publishId}`;
}

export function ratePk(id: string) {
  return `RATE#${id}`;
}

type Item = Record<string, unknown>;
type OwnerFields = { ownerUid: string | null; legacyOwnerUid: string | null; acl: Record<string, Role> };

export class DynamoMetadata implements MetadataStore {
  private readonly doc: DynamoDBDocumentClient;
  private readonly table: string;

  constructor(doc: DynamoDBDocumentClient, table: string) {
    this.doc = doc;
    this.table = table;
  }

  async getBuilding(id: string) {
    const item = await this.get(buildingPk(id), 'META');
    return item ? mapBuilding(id, item) : null;
  }

  async createBuilding(record: BuildingRecord) {
    try {
      await this.doc.send(new PutCommand({
        TableName: this.table,
        Item: buildingItem(record),
        ConditionExpression: 'attribute_not_exists(PK)',
      }));
      return 'created' as const;
    } catch (error) {
      if (isConditional(error)) return 'exists' as const;
      throw error;
    }
  }

  async listBuildings() {
    const items = await this.queryAll({
      TableName: this.table,
      IndexName: 'GSI1',
      KeyConditionExpression: 'GSI1PK = :pk',
      ExpressionAttributeValues: { ':pk': BUILDINGS },
    });
    return items.map(item => mapBuilding(String(item.buildingId || buildingIdFromPk(item.PK)), item));
  }

  async getVersion(buildingId: string, versionId: string) {
    const item = await this.get(buildingPk(buildingId), versionSk(versionId));
    return item ? mapVersion(versionId, item) : null;
  }

  async listVersionIds(buildingId: string) {
    const items = await this.queryPrefix(buildingId, 'VERSION#');
    return items.map(item => String(item.versionId || String(item.SK).slice('VERSION#'.length)));
  }

  async listZones(buildingId: string, versionId: string) {
    const items = await this.queryPrefix(buildingId, `ZONE#${versionId}#`);
    return items.map(item => mapZone(String(item.zoneId || zoneIdFromSk(String(item.SK), versionId)), item));
  }

  async listFloors(buildingId: string, versionId: string) {
    const items = await this.queryPrefix(buildingId, `FLOOR#${versionId}#`);
    return items.map(item => mapFloor(String(item.floorId || floorIdFromSk(String(item.SK), versionId)), item));
  }

  async listPublishes(buildingId: string) {
    const items = await this.queryPrefix(buildingId, 'PUBLISH#');
    return items.map(mapPublish).filter((item): item is PublishRecord => item !== null);
  }

  async savePublish(record: PublishRecord) {
    await this.doc.send(new PutCommand({
      TableName: this.table,
      Item: publishItem(record),
    }));
  }

  async getPublish(buildingId: string, publishId: string) {
    const item = await this.get(buildingPk(buildingId), publishSk(publishId));
    return item ? mapPublish(item) : null;
  }

  async commit(write: CommitWrite) {
    const building = await this.getBuilding(write.buildingId);
    const existing = await this.getPublish(write.buildingId, write.publishId);
    if (!existing) throw new ApiError(404, 'not_found', 'That publish session does not exist.');
    if (existing.status === 'committed') return 'already' as const;
    const owner = ownerFields(building);
    const now = new Date().toISOString();
    const expectedMissing = write.carriedFromVersion == null;
    try {
      await this.doc.send(new TransactWriteCommand({
        TransactItems: [
          {
            Update: {
              TableName: this.table,
              Key: { PK: buildingPk(write.buildingId), SK: 'META' },
              UpdateExpression: 'SET activeVersion = :versionId, #status = :active, updatedAt = :now, versionId = :versionId',
              ConditionExpression: 'attribute_exists(PK) AND (activeVersion = :expected OR (attribute_not_exists(activeVersion) AND :missing = :yes) OR (activeVersion = :null AND :missing = :yes))',
              ExpressionAttributeNames: { '#status': 'status' },
              ExpressionAttributeValues: {
                ':versionId': write.versionId,
                ':active': 'active',
                ':now': now,
                ':expected': write.carriedFromVersion,
                ':missing': expectedMissing ? 'yes' : 'no',
                ':yes': 'yes',
                ':null': null,
              },
            },
          },
          {
            Update: {
              TableName: this.table,
              Key: { PK: buildingPk(write.buildingId), SK: publishSk(write.publishId) },
              UpdateExpression: 'SET #status = :committed, committedAt = :now, #record.#status = :committed, #record.committedAt = :now',
              ConditionExpression: 'attribute_exists(PK) AND #status = :open AND expiresAt > :now',
              ExpressionAttributeNames: { '#status': 'status', '#record': 'record' },
              ExpressionAttributeValues: { ':committed': 'committed', ':open': 'open', ':now': now },
            },
          },
          {
            Put: {
              TableName: this.table,
              Item: versionItem(write.buildingId, write.version, owner),
              ConditionExpression: 'attribute_not_exists(PK)',
            },
          },
          ...write.zones.map(zone => ({
            Put: {
              TableName: this.table,
              Item: zoneItem(write.buildingId, write.versionId, zone, owner),
              ConditionExpression: 'attribute_not_exists(PK)',
            },
          })),
          ...write.floors.map(floor => ({
            Put: {
              TableName: this.table,
              Item: floorItem(write.buildingId, write.versionId, floor, owner),
              ConditionExpression: 'attribute_not_exists(PK)',
            },
          })),
        ],
      }));
      return 'committed' as const;
    } catch (error) {
      if (!isConditional(error)) throw error;
      const publish = await this.getPublish(write.buildingId, write.publishId);
      if (publish?.status === 'committed') return 'already' as const;
      const current = await this.getBuilding(write.buildingId);
      if ((current?.activeVersion ?? null) !== (write.carriedFromVersion ?? null)) {
        throw new ApiError(409, 'building_changed', 'The building changed while the package uploaded. Publish it again.');
      }
      if (publish && Date.parse(publish.expiresAt) <= Date.now()) {
        throw new ApiError(409, 'publish_expired', 'The publish session expired before the package was checked. Start it again.');
      }
      throw new ApiError(409, 'conflict', 'The publish could not be committed.');
    }
  }

  async updatePointer(update: PointerUpdate) {
    const key = {
      PK: buildingPk(update.buildingId),
      SK: update.zoneId ? zoneSk(update.versionId, update.zoneId) : versionSk(update.versionId),
    };
    const names: Record<string, string> = { '#path': update.pathField, '#marker': update.markerField };
    const values: Record<string, unknown> = {
      ':path': update.path,
      ':marker': update.marker,
      ':expectedPath': update.expectedPath,
      ':expectedMarker': update.expectedMarker,
      ':empty': '',
      ':null': null,
      ':now': new Date().toISOString(),
    };
    try {
      await this.doc.send(new UpdateCommand({
        TableName: this.table,
        Key: key,
        UpdateExpression: 'SET #path = :path, #marker = :marker, updatedAt = :now',
        ConditionExpression: [
          'attribute_exists(PK)',
          matchField('#path', ':expectedPath'),
          matchField('#marker', ':expectedMarker'),
        ].join(' AND '),
        ExpressionAttributeNames: names,
        ExpressionAttributeValues: values,
      }));
      return 'updated' as const;
    } catch (error) {
      if (!isConditional(error)) throw error;
      const item = await this.get(key.PK, key.SK);
      if (!item) return 'missing' as const;
      return 'conflict' as const;
    }
  }

  async patchRecord(path: string, before: Record<string, unknown>, after: Record<string, unknown>) {
    const ref = parseRecordPath(path);
    if (!ref) return 'missing' as const;
    const current = await this.recordView(ref);
    if (!current) return 'missing' as const;
    if (canonical(current) !== canonical(before)) return 'conflict' as const;
    const structural = new Set(['id', 'buildingId', 'versionId', 'zoneId', 'floorId', 'publishId']);
    for (const key of structural) {
      if (key in after && canonical(after[key]) !== canonical(current[key])) {
        throw new ApiError(400, 'invalid_json', `${key} cannot be changed.`);
      }
    }
    const key = recordKey(ref);
    if (!key) return 'missing' as const;
    if (ref.kind === 'publish') {
      const publish = { ...current, ...after, id: ref.publishId, buildingId: ref.buildingId } as PublishRecord;
      await this.doc.send(new UpdateCommand({
        TableName: this.table,
        Key: key,
        UpdateExpression: 'SET #record = :record, #status = :status, expiresAt = :expiresAt, updatedAt = :now',
        ConditionExpression: 'attribute_exists(PK)',
        ExpressionAttributeNames: { '#record': 'record', '#status': 'status' },
        ExpressionAttributeValues: {
          ':record': publish,
          ':status': publish.status,
          ':expiresAt': publish.expiresAt,
          ':now': new Date().toISOString(),
        },
      }));
      return 'saved' as const;
    }
    const names: Record<string, string> = {};
    const values: Record<string, unknown> = { ':now': new Date().toISOString() };
    const sets = ['updatedAt = :now'];
    const removes: string[] = [];
    let index = 0;
    for (const [field, value] of Object.entries(after)) {
      if (structural.has(field) || field === 'updatedAt') continue;
      if (canonical(value) === canonical(current[field])) continue;
      const token = `#f${index}`;
      names[token] = field;
      values[`:v${index}`] = value;
      sets.push(`${token} = :v${index}`);
      index += 1;
    }
    for (const field of Object.keys(current)) {
      if (structural.has(field) || field === 'updatedAt' || field in after) continue;
      const token = `#f${index}`;
      names[token] = field;
      removes.push(token);
      index += 1;
    }
    let expression = 'SET ' + sets.join(', ');
    if (removes.length) expression += ' REMOVE ' + removes.join(', ');
    await this.doc.send(new UpdateCommand({
      TableName: this.table,
      Key: key,
      UpdateExpression: expression,
      ConditionExpression: 'attribute_exists(PK)',
      ...(Object.keys(names).length ? { ExpressionAttributeNames: names } : {}),
      ExpressionAttributeValues: values,
    }));
    return 'saved' as const;
  }

  private async recordView(ref: NonNullable<ReturnType<typeof parseRecordPath>>): Promise<Record<string, unknown> | null> {
    if (ref.kind === 'building') {
      const building = await this.getBuilding(ref.buildingId);
      return building ? buildingData(building) : null;
    }
    if (ref.kind === 'version') {
      const version = await this.getVersion(ref.buildingId, ref.versionId);
      return version ? { ...version } : null;
    }
    if (ref.kind === 'zone') {
      const zone = (await this.listZones(ref.buildingId, ref.versionId)).find(item => item.id === ref.zoneId);
      return zone ? { ...zone } : null;
    }
    if (ref.kind === 'floor') {
      const floor = (await this.listFloors(ref.buildingId, ref.versionId)).find(item => item.id === ref.floorId);
      return floor ? { ...floor } : null;
    }
    const publish = await this.getPublish(ref.buildingId, ref.publishId);
    return publish ? { ...publish } : null;
  }

  private async get(pk: string, sk: string) {
    const out = await this.doc.send(new GetCommand({
      TableName: this.table,
      Key: { PK: pk, SK: sk },
      ConsistentRead: true,
    }));
    return (out.Item as Item | undefined) ?? null;
  }

  private async queryPrefix(buildingId: string, prefix: string) {
    return this.queryAll({
      TableName: this.table,
      KeyConditionExpression: 'PK = :pk AND begins_with(SK, :sk)',
      ExpressionAttributeValues: { ':pk': buildingPk(buildingId), ':sk': prefix },
      ConsistentRead: true,
    });
  }

  private async queryAll(input: ConstructorParameters<typeof QueryCommand>[0]) {
    const items: Item[] = [];
    let start: Record<string, unknown> | undefined;
    do {
      const page = await this.doc.send(new QueryCommand({ ...input, ExclusiveStartKey: start }));
      for (const item of page.Items ?? []) items.push(item as Item);
      start = page.LastEvaluatedKey as Record<string, unknown> | undefined;
    } while (start);
    return items;
  }
}

export class DynamoCounters implements CounterStore {
  private readonly doc: DynamoDBDocumentClient;
  private readonly table: string;
  private readonly wait: (ms: number) => Promise<void>;

  constructor(doc: DynamoDBDocumentClient, table: string, wait: (ms: number) => Promise<void> = delay) {
    this.doc = doc;
    this.table = table;
    this.wait = wait;
  }

  async consume(keys: RateKey[]) {
    if (!keys.length) return { ok: true as const };
    const ttl = Math.floor(Date.now() / 1000) + 2 * 60 * 60;
    // Separate updates so concurrent page loads do not cancel each other.
    // A transaction touching the same three counters fails with TransactionConflict, which is not a quota rejection.
    const results = await Promise.all(keys.map(key => this.increment(key, ttl)));
    return results.some(result => result === 'limited') ? { ok: false as const } : { ok: true as const };
  }

  private async increment(key: RateKey, ttl: number): Promise<'ok' | 'limited'> {
    const attempts = 4;
    for (let attempt = 0; attempt < attempts; attempt += 1) {
      try {
        await this.doc.send(new UpdateCommand({
          TableName: this.table,
          Key: { PK: ratePk(key.id), SK: 'RATE' },
          UpdateExpression: 'SET #count = if_not_exists(#count, :zero) + :one, #ttl = :ttl, #kind = :kind',
          ConditionExpression: 'attribute_not_exists(#count) OR #count < :limit',
          ExpressionAttributeNames: { '#count': 'count', '#ttl': 'ttl', '#kind': 'type' },
          ExpressionAttributeValues: {
            ':zero': 0,
            ':one': 1,
            ':ttl': ttl,
            ':kind': 'rate',
            ':limit': key.limit,
          },
        }));
        return 'ok';
      } catch (error) {
        if (isConditionalCheckFailed(error)) return 'limited';
        if (!isContention(error) || attempt === attempts - 1) {
          if (isContention(error)) return 'ok';
          throw error;
        }
        await this.wait(backoffMs(attempt));
      }
    }
    return 'ok';
  }
}

export function buildingItem(record: BuildingRecord): Item {
  return {
    PK: buildingPk(record.id),
    SK: 'META',
    GSI1PK: BUILDINGS,
    GSI1SK: buildingPk(record.id),
    type: 'building',
    buildingId: record.id,
    versionId: record.activeVersion,
    name: record.name,
    status: record.status,
    activeVersion: record.activeVersion,
    ownerUid: record.ownerUid,
    legacyOwnerUid: record.legacyOwnerUid ?? null,
    acl: record.acl ?? {},
    visibility: record.visibility,
    ...(record.latitude == null ? {} : { latitude: record.latitude }),
    ...(record.longitude == null ? {} : { longitude: record.longitude }),
    ...(record.mapHeadingDegrees == null ? {} : { mapHeadingDegrees: record.mapHeadingDegrees }),
    ...(record.metadataOnly ? { metadataOnly: true } : {}),
  };
}

function versionItem(buildingId: string, version: VersionRecord, owner: OwnerFields): Item {
  return {
    PK: buildingPk(buildingId),
    SK: versionSk(version.id),
    type: 'version',
    buildingId,
    versionId: version.id,
    versionNumber: version.versionNumber,
    status: version.status,
    buildingLayoutPath: version.buildingLayoutPath ?? null,
    zoneConnectionsPath: version.zoneConnectionsPath ?? null,
    buildingJsonPath: version.buildingJsonPath ?? null,
    scanFeaturesPath: version.scanFeaturesPath ?? null,
    structurePath: version.structurePath ?? null,
    ...(version.publishId ? { publishId: version.publishId } : {}),
    ...(version.webGraphRevision ? { webGraphRevision: version.webGraphRevision } : {}),
    ...(version.webBuildingLayoutRevision ? { webBuildingLayoutRevision: version.webBuildingLayoutRevision } : {}),
    ...(version.webZoneConnectionsRevision ? { webZoneConnectionsRevision: version.webZoneConnectionsRevision } : {}),
    ...owner,
  };
}

function zoneItem(buildingId: string, versionId: string, zone: ZoneRecord, owner: OwnerFields): Item {
  return {
    PK: buildingPk(buildingId),
    SK: zoneSk(versionId, zone.id),
    type: 'zone',
    buildingId,
    versionId,
    zoneId: zone.id,
    name: zone.name,
    floorId: zone.floorId,
    ...(zone.worldMapPath ? { worldMapPath: zone.worldMapPath } : {}),
    ...(zone.buildingJsonPath ? { buildingJsonPath: zone.buildingJsonPath } : {}),
    ...(zone.scanJsonPath ? { scanJsonPath: zone.scanJsonPath } : {}),
    ...(zone.scanFeaturesPath ? { scanFeaturesPath: zone.scanFeaturesPath } : {}),
    ...(zone.structurePath ? { structurePath: zone.structurePath } : {}),
    ...(zone.surfaceColorsPath ? { surfaceColorsPath: zone.surfaceColorsPath } : {}),
    ...(zone.surfaceColorAtlasPath ? { surfaceColorAtlasPath: zone.surfaceColorAtlasPath } : {}),
    ...(zone.transformsPath ? { transformsPath: zone.transformsPath } : {}),
    ...(zone.gaussianSplatPath ? { gaussianSplatPath: zone.gaussianSplatPath } : {}),
    ...(zone.gaussianSplatDataPath ? { gaussianSplatDataPath: zone.gaussianSplatDataPath } : {}),
    ...(zone.texturedMeshPath ? { texturedMeshPath: zone.texturedMeshPath } : {}),
    ...(zone.texturedMeshMetadataPath ? { texturedMeshMetadataPath: zone.texturedMeshMetadataPath } : {}),
    ...(zone.relocalizationHint ? { relocalizationHint: zone.relocalizationHint } : {}),
    ...(zone.startNodeId ? { startNodeId: zone.startNodeId } : {}),
    ...(zone.webGraphRevision ? { webGraphRevision: zone.webGraphRevision } : {}),
    ...owner,
  };
}

function floorItem(buildingId: string, versionId: string, floor: FloorRecord, owner: OwnerFields): Item {
  return {
    PK: buildingPk(buildingId),
    SK: floorSk(versionId, floor.id),
    type: 'floor',
    buildingId,
    versionId,
    floorId: floor.id,
    name: floor.name,
    story: floor.story,
    elevation: floor.elevation,
    ...owner,
  };
}

function publishItem(record: PublishRecord): Item {
  return {
    PK: buildingPk(record.buildingId),
    SK: publishSk(record.id),
    type: 'publish',
    buildingId: record.buildingId,
    versionId: record.versionId,
    publishId: record.id,
    status: record.status,
    expiresAt: record.expiresAt,
    uid: record.uid,
    ownerUid: null,
    legacyOwnerUid: null,
    acl: {},
    record,
  };
}

function ownerFields(building: BuildingRecord | null): OwnerFields {
  return {
    ownerUid: building?.ownerUid ?? null,
    legacyOwnerUid: building?.legacyOwnerUid ?? null,
    acl: building?.acl ?? {},
  };
}

function mapBuilding(id: string, item: Item): BuildingRecord {
  return {
    id,
    name: text(item.name, id),
    status: text(item.status, 'draft'),
    activeVersion: nullableText(item.activeVersion),
    ownerUid: nullableText(item.ownerUid),
    legacyOwnerUid: nullableText(item.legacyOwnerUid),
    acl: mapAcl(item.acl),
    visibility: item.visibility === 'members' ? 'members' : 'authenticated',
    ...(typeof item.latitude === 'number' ? { latitude: item.latitude } : {}),
    ...(typeof item.longitude === 'number' ? { longitude: item.longitude } : {}),
    ...(typeof item.mapHeadingDegrees === 'number' ? { mapHeadingDegrees: item.mapHeadingDegrees } : {}),
    ...(item.metadataOnly === true ? { metadataOnly: true } : {}),
  };
}

function mapVersion(id: string, item: Item): VersionRecord {
  return {
    id,
    versionNumber: Number(item.versionNumber || 0),
    status: text(item.status, 'draft'),
    buildingLayoutPath: nullableText(item.buildingLayoutPath),
    zoneConnectionsPath: nullableText(item.zoneConnectionsPath),
    buildingJsonPath: nullableText(item.buildingJsonPath),
    scanFeaturesPath: nullableText(item.scanFeaturesPath),
    structurePath: nullableText(item.structurePath),
    ...(item.publishId ? { publishId: String(item.publishId) } : {}),
    ...(typeof item.webGraphRevision === 'string' ? { webGraphRevision: item.webGraphRevision } : {}),
    ...(typeof item.webBuildingLayoutRevision === 'string' ? { webBuildingLayoutRevision: item.webBuildingLayoutRevision } : {}),
    ...(typeof item.webZoneConnectionsRevision === 'string' ? { webZoneConnectionsRevision: item.webZoneConnectionsRevision } : {}),
  };
}

function mapZone(id: string, item: Item): ZoneRecord {
  const optional = (field: string) => (item[field] ? String(item[field]) : undefined);
  return {
    id,
    name: text(item.name, id),
    floorId: text(item.floorId, 'ground'),
    worldMapPath: optional('worldMapPath'),
    buildingJsonPath: optional('buildingJsonPath'),
    scanJsonPath: optional('scanJsonPath'),
    scanFeaturesPath: optional('scanFeaturesPath'),
    structurePath: optional('structurePath'),
    surfaceColorsPath: optional('surfaceColorsPath'),
    surfaceColorAtlasPath: optional('surfaceColorAtlasPath'),
    transformsPath: optional('transformsPath'),
    gaussianSplatPath: optional('gaussianSplatPath'),
    gaussianSplatDataPath: optional('gaussianSplatDataPath'),
    texturedMeshPath: optional('texturedMeshPath'),
    texturedMeshMetadataPath: optional('texturedMeshMetadataPath'),
    relocalizationHint: optional('relocalizationHint'),
    startNodeId: optional('startNodeId'),
    webGraphRevision: optional('webGraphRevision'),
  };
}

function mapFloor(id: string, item: Item): FloorRecord {
  return { id, name: text(item.name, id), story: Number(item.story || 0), elevation: Number(item.elevation || 0) };
}

function mapPublish(item: Item): PublishRecord | null {
  const record = item.record;
  if (!record || typeof record !== 'object' || Array.isArray(record)) return null;
  const publish = record as PublishRecord;
  if (item.status === 'committed' || item.status === 'open') publish.status = item.status;
  if (typeof item.committedAt === 'string') publish.committedAt = item.committedAt;
  return publish;
}

function mapAcl(value: unknown): Record<string, Role> {
  const acl: Record<string, Role> = {};
  if (!value || typeof value !== 'object' || Array.isArray(value)) return acl;
  for (const [uid, role] of Object.entries(value as Record<string, unknown>)) {
    if (role === 'owner' || role === 'editor' || role === 'viewer') acl[uid] = role;
  }
  return acl;
}

function recordKey(ref: NonNullable<ReturnType<typeof parseRecordPath>>) {
  if (ref.kind === 'building') return { PK: buildingPk(ref.buildingId), SK: 'META' };
  if (ref.kind === 'version') return { PK: buildingPk(ref.buildingId), SK: versionSk(ref.versionId) };
  if (ref.kind === 'zone') return { PK: buildingPk(ref.buildingId), SK: zoneSk(ref.versionId, ref.zoneId) };
  if (ref.kind === 'floor') return { PK: buildingPk(ref.buildingId), SK: floorSk(ref.versionId, ref.floorId) };
  return { PK: buildingPk(ref.buildingId), SK: publishSk(ref.publishId) };
}

function matchField(token: string, expected: string) {
  return `(${token} = ${expected} OR (attribute_not_exists(${token}) AND ${expected} = :empty) OR (${token} = :null AND ${expected} = :empty))`;
}

function text(value: unknown, fallback: string) {
  return typeof value === 'string' && value ? value : fallback;
}

function nullableText(value: unknown) {
  return typeof value === 'string' && value ? value : null;
}

function buildingIdFromPk(value: unknown) {
  const pk = String(value || '');
  return pk.startsWith('BUILDING#') ? pk.slice('BUILDING#'.length) : pk;
}

function zoneIdFromSk(sk: string, versionId: string) {
  const prefix = `ZONE#${versionId}#`;
  return sk.startsWith(prefix) ? sk.slice(prefix.length) : sk;
}

function floorIdFromSk(sk: string, versionId: string) {
  const prefix = `FLOOR#${versionId}#`;
  return sk.startsWith(prefix) ? sk.slice(prefix.length) : sk;
}

function delay(ms: number): Promise<void> {
  return new Promise(resolve => {
    setTimeout(() => resolve(), ms);
  });
}

function backoffMs(attempt: number) {
  const base = 15 * 2 ** attempt;
  return base + Math.floor(Math.random() * base);
}

function isConditionalCheckFailed(error: unknown) {
  if (!error || typeof error !== 'object') return false;
  const name = (error as { name?: string }).name;
  if (name === 'ConditionalCheckFailedException') return true;
  if (name !== 'TransactionCanceledException') return false;
  const reasons = (error as { CancellationReasons?: { Code?: string }[] }).CancellationReasons ?? [];
  return reasons.some(reason => reason.Code === 'ConditionalCheckFailed');
}

function isContention(error: unknown) {
  if (!error || typeof error !== 'object') return false;
  const name = (error as { name?: string }).name;
  if (name === 'TransactionConflictException' || name === 'TransactionInProgressException') return true;
  if (name !== 'TransactionCanceledException') return false;
  const reasons = (error as { CancellationReasons?: { Code?: string }[] }).CancellationReasons ?? [];
  return reasons.some(reason => reason.Code === 'TransactionConflict') && !reasons.some(reason => reason.Code === 'ConditionalCheckFailed');
}

function isConditional(error: unknown) {
  if (!error || typeof error !== 'object') return false;
  const name = (error as { name?: string }).name;
  if (name === 'ConditionalCheckFailedException') return true;
  if (name !== 'TransactionCanceledException') return false;
  const reasons = (error as { CancellationReasons?: { Code?: string }[] }).CancellationReasons;
  if (!reasons?.length) return true;
  return reasons.every(reason => !reason.Code || reason.Code === 'None' || reason.Code === 'ConditionalCheckFailed');
}

