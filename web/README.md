# Gnarly web companion

Run locally:

```sh
cd web
npm install
npm run dev
```

For a built deployment, run `npm run build && npm start`. The Node server serves `dist/` and proxies signed downloads for the S3 bucket (and a Firebase bucket only if `FIREBASE_STORAGE_BUCKET` is set). A static host can fetch the presigned S3 URLs directly; that bucket already allows this site's origin.

The site opens in a labeled sample mode centered on the Cornell area. The **North Hall** building, floor layout, destinations, and two-floor route are illustrative. Add `VITE_GOOGLE_MAPS_API_KEY` to `web/.env` to use Google Maps. Without it, OpenStreetMap remains available.

## Google Maps setup

1. In the Google Cloud project associated with Firebase, enable **Maps JavaScript API** and confirm billing is configured.
2. In **APIs & Services → Credentials**, create or select a browser API key. Restrict it to **Websites** (`http://localhost:5173/*` for local development and your deployed domain later) and to **Maps JavaScript API**.
3. In **Google Maps Platform → Map Management**, create a **JavaScript vector** map ID. Put the key and map ID in `web/.env` as `VITE_GOOGLE_MAPS_API_KEY` and `VITE_GOOGLE_MAPS_MAP_ID`.
4. Restart `npm run dev`. The map should show Google’s own attribution along its bottom edge. If the map shows a Google error, check browser console, billing, key restrictions, and whether Maps JavaScript API is enabled.

Browser API keys are visible in the site bundle; HTTP referrer and API restrictions are the relevant protections. Do not use a service-account key here.

## Connect the cloud API

1. Copy `web/.env.example` to `web/.env`. `VITE_GNARLY_API_BASE` defaults to the deployed Function URL. Set `VITE_COGNITO_REDIRECT_URI` to `http://localhost:5173/` for local dev, or `https://naijei.com/gnarly/` for the hosted site. Set `VITE_BASE=/gnarly/` only for that hosted build. Do not put a secret in this file.
2. Anyone can view buildings. **Sign in with Google** is only for editing, and only `nj277@cornell.edu` (or `VITE_ADMIN_EMAILS`) with a verified email sees the edit UI. The API enforces the same rule from the Cognito ID token. Email and password remain a fallback. This app does not create Cognito users.
3. A building item needs `name`, `status`, and `activeVersion`. Latitude and longitude place it on the map. Records without them appear in search but cannot have a map marker.
4. Objects stay at `buildings/{id}/{version}/...` (the same keys as Firebase Storage, including keys that contain spaces). Version, zone, and floor rows live in the DynamoDB table `gnarly`. The browser downloads presigned S3 URLs directly. Bucket CORS already allows `https://naijei.com` and `http://localhost:5173`.

For a built deployment, `npm run build && npm start` still proxies signed URLs through `/__signed`, now for the S3 bucket as well as a Firebase bucket if `FIREBASE_STORAGE_BUCKET` is set. Static hosting should use the presigned URL directly; S3 CORS covers the site origin.

The waypoint editor reads and writes graph packages through the publish API. An edit uploads `graph-edits/<uuid>.json` with a presigned PUT, then moves the zone pointer only if it has not changed. Buildings with missing active versions or package assets show an unavailable state. The iOS export schema is zone-based. The website combines zones into one building graph using `building-layout.json` and `zone-connections.json`; see **Zones, floors, and elevators** below.

### Browser downloads and CORS

The website asks the publish API for a signed URL and fetches it in the browser. On AWS that URL is an S3 presigned GET. `https://naijei.com` and `http://localhost:5173` are already allowed by the bucket CORS, including for a static host with no Node proxy. `npm start` can still proxy the same URL through `/__signed`.

If a Firebase bucket is still in use, a static host needs that bucket's CORS to allow the site origin with `GET`. A local sample rule is in `firebase/cors.web.local.json`. For a bucket with no other CORS needs, they can apply it from the repository root with:

```sh
gcloud storage buckets update gs://gnarly-e65c1.firebasestorage.app --cors-file=firebase/cors.web.local.json
```

The update replaces a Firebase bucket's CORS configuration, so merge this rule with any existing rules first. The AWS bucket is already configured for this site and does not need that command.

## Project data workspace

Use **Data** in the site header. It lists building, version, floor, zone, and publish records from the API. Anyone can read them. The verified admin email can edit a document: change the JSON, review changed or removed top-level fields, then save. Saves are rejected if the record changed since it was opened. The workspace can also preview JSON files linked by a zone's `buildingJsonPath`, `scanFeaturesPath`, or `scanJsonPath`. Scan uploads still go through the mapper.

## 3D assets

The mapper exports `scan-features.json` alongside `structure.usdz`, `scan.json`, and `building.json` for each zone. The browser reads the zone's feature JSON and renders RoomPlan floors, walls, openings, doors, windows, and objects in ARKit world coordinates. For floors, it triangulates the captured `polygonCorners` in the floor’s local plane and applies the RoomPlan transform; scans without a polygon use a rectangular fallback. Door, opening, and window outlines cut holes in their parent walls; the original USDZ stays in Storage for iOS and later mesh conversion. When the zone has `surface-colors.json` and `surface-colors.jpg`, walls, floors, doors, windows and objects are textured with the real colors photographed during the scan (unlit, so the captured lighting is shown as-is). Without them the default palette is used. A live zone without scan features shows its route graph only. The sample building's enclosing walls are illustrative. One scan covers only its captured room/zone. Each zone is drawn in its own ARKit frame, placed on its floor by the building layout.

Build check: `npm run build`.

## Drop-to-walk view

In the building explorer, drag **Drop to walk** onto any visible floor. The viewer switches to that floor and places the camera at eye height. Drag inside the scene to look around, use W/S or the up/down arrows to move, and use A/D or the left/right arrows to turn in place. Hold Shift to move faster. The on-screen direction pad provides the same movement and turning controls on touch devices. Choose **Exit** to return to the orbiting overview; the person marker remains at the last walk position and can be dragged somewhere else.

Walk mode stays inside the selected floor boundary. Hold Shift to run. Standing within 1.5 m of a linked elevator shows an **Elevator** panel: press E (or Page Up) to ride to the next floor up and Q (or Page Down) to ride down, or tap the buttons. Walking off one zone's scanned floor onto another zone's floor at the same level moves the person into that zone, unless a scanned wall is in the way. When `scan-features.json` is available, movement is also stopped by scanned walls and can cross them only through a captured door or opening. On graph-only packages, the generated floor bounds are used because wall geometry is not available.

## Waypoint editor and routing

The building explorer has two modes. **View paths** picks a start and destination anywhere in the building, draws the route across zones and floors, and lists its steps (walk legs, "Continue into …", "Take the elevator from … to …"); clicking a leg shows that floor. **Edit map** edits one zone's waypoints at a time; pick the zone from **Editing zone** or click a waypoint in another zone. Select, add by clicking a floor, move by clicking a floor or entering XYZ meters, edit name/type/floor, connect two waypoints, or delete a waypoint and its incident edges. The site preserves existing waypoint IDs. Its coordinates are the package's ARKit world coordinates. An affected edge's `meters` is recalculated from 3D endpoint distance when a waypoint moves. The editor validates IDs, endpoints, floors, distances, floor surfaces, walls, and stair transitions before saving. Existing blocked connections are shown and excluded from routes; an unrelated edit may be saved, but newly blocked connections must be fixed. Cancel restores the last saved graph. Unsaved graph edits and unapplied waypoint fields are backed up in session storage for the current tab, so they survive refresh and in-app navigation without replacing a draft in another tab. Closing the tab ends that draft session; save first. Leaving prompts before navigation. Apply waypoint fields before saving the graph. Cancel restores the latest saved graph, including a newer revision received during a conflict.

**Local test · browser only** saves in browser storage and is labeled **not synced**. Cloud mode is available to the verified admin. It writes an immutable `graph-edits/<uuid>.json` object with a presigned PUT, then conditionally moves that zone's `buildingJsonPath` pointer if the pointer has not changed. Other open web clients reload on a periodic check. A changed pointer while a local draft exists raises a conflict and keeps the draft. The previous graph object remains in the bucket. The Unity navigator and mapper package download accept that pointer path.

Cloud saves require the verified admin email. The API rejects everyone else, and the edit controls stay hidden. A presigned PUT from the browser needs the bucket CORS to allow `PUT` from this origin (GET is already allowed for `https://naijei.com` and `http://localhost:5173`). A failed save retains the local draft and shows **Save failed**.

**Auto-connect waypoints** adds visibility edges inside the editing zone, like the Unity navigator's `ConnectVisibility`: same floor, 0.2–18 m apart, and only where the scan check passes (so through doors, never walls). It skips pairs that are both plain walk-path points and needs `scan-features.json`. Review the added edges, then save.

`src/routing.ts` is the single-zone algorithm handoff point. `findRoute({ graph, startId, destinationId, options: { scan } })` returns either `{ ok: true, nodes, edges, distance, floorTransitions, unverifiedEdges, warningEdges }` with ordered nodes and edges, or `{ ok: false, reason, message }` for invalid endpoints or no route. Example: `findRoute({ graph, startId: 'entrance', destinationId: 'stairs-top', options: { scan } })`. It runs a binary-heap Dijkstra (`shortestPath`) over `edge.meters`, respects directed edges (`bidirectional: false`), and checks every candidate edge through `checkEdge()` in `src/geometry.ts`. Building-wide routes use `findBuildingRoute(model, startKey, destinationKey)` from `src/buildingGraph.ts`, with node keys of the form `zoneId/nodeId` (the same as the Unity `ZoneKey`). It returns the same fields plus `walkingMeters`, per-zone `legs`, and `transitions`. The preview draws consecutive route edges, without smoothing.

Wall safety depends on `scan-features.json`: a connection must stay on scanned floor polygons and cross a wall only where a matched door or opening exists. Cross-floor edges must explicitly connect stair waypoints. `recorded` and `walked-path` edges were physically walked by the mapper and are always routable. When the scan disagrees with one (for example, a wall or polygon edge from a slightly misaligned scan), it is marked **warning** instead of blocked. `manual` and `visibility` edges remain strict. Where scan features are missing, only `manual`, `recorded`, or `walked-path` edges are usable, and the UI labels them **unverified**. Such edges have no automatic wall guarantee; an operator must confirm them against the actual space. Other edges without scan data are blocked. If no approved graph path exists, the viewer says **No walkable route found.**

## Zones, floors, and elevators

A building has floors, and a floor is made of one or more scanned zones. Each zone keeps its own ARKit coordinates; scan data is never rewritten. `building-layout.json` assigns each zone a `floor` and places it in that floor's shared frame with `x`, `z`, and `rotationDegrees` (rotation about the vertical axis). An optional `floors: [{ floor, name }]` list names floors. Zones without a layout entry are placed automatically. Their floor comes from continuation links, the graph's floor stories, or the number in the zone name.

- **Continuation links** join two zones on the same floor where one scan ends and the next begins. One linked pair snaps the second zone into position; two or more spread-out pairs also solve its rotation. Use **Edit map → Join zones on a floor** to place a zone start/end point and link it to the matching point in the other zone, then fine-tune under **Zone placement** (floor level, floor name, X/Z, rotation, **Auto-align to joined zones**, **Save zone placement**). Saving a placement fixes every zone at its current position, so adjusting one zone does not move the others. The route crosses a continuation link as a short walk. Once zones are joined, their paths merge too. Each waypoint is linked to its nearest waypoints (up to two) in each joined zone within 1.5 m. These seam links are computed, not saved, and are shown in teal in **Edit map**. A seam link is dropped if it crosses a wall in either zone's scan, and each crossing costs an extra 1 m so routes don't zig-zag between overlapping scans.
- **Move whole floor** (under **Zone placement**) shifts or turns every zone on the editing zone's floor together, by the chosen step, keeping their joins. **Align floor to elevators** moves the floor so its elevators sit directly above or below the elevators they are linked to, using the linked floor with the most elevator links. One elevator fixes position; two or more also fix rotation. Save the zone placement afterwards.
- **Elevator links** connect elevator waypoints on different floors and act as a teleport. They don't move floors on their own (use **Align floor to elevators**), and the zones stay separate. Linked elevators form a shaft. Riding between any two floors in a shaft costs 30 + 6 per floor travelled, the same as Unity's `Pathfinding.cs`. Use **Edit map → Elevators between floors** to link an existing elevator or place a matching one in a zone on the destination floor. Linking two elevators on the same floor is rejected.

Zone links and layout are stored with the rest of the data mode: browser storage in **Local test** (keys `gnarly-local-zone-links:…` and `gnarly-local-layout:…`), or `zone-connections.json` and `building-layout.json` in cloud mode. The sample North Hall shows all three: Floor 1 west and Floor 1 east (scanned at a 90° rotation) joined by two continuation pairs, and an elevator up to Floor 2.

Run `npm test` from `web/` for the wall, doorway, corner, stairs, edit, auto-connect, alignment, and building-route checks.

## Website polish verification

Run `npm test` and `npm run build` from `web/`. Regression tests cover walls and door detours, concave floors and small gaps, portals on another story, directed edges, invalid distances, empty-floor placement, preserving recorded distances during a rename, trusted walked edges, auto-connect, zone alignment, and continuation/elevator building routes.

Browser checks cover local save/refresh, unapplied-field leave warnings, two-tab conflicts and Cancel, route selection, typing while walking, and a 390px-wide editing/route layout. The data browser filters documents, reports load errors without requiring a selected record, and warns before discarding JSON changes through header navigation or reload. Cloud graph writes still need a live check as the verified admin.

The 3D workspace and the record editor load on demand. Large bundles still produce Vite’s size advisory, but opening the map no longer downloads the 3D workspace.
