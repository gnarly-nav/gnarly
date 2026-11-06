# Create and run the mapper app

This project is defined with [XcodeGen](https://github.com/yonaskolb/XcodeGen) so the Xcode project is reproducible and does not need to be committed.

## Prerequisites

- Xcode with the iOS 17 SDK
- A LiDAR-capable iPhone running iOS 17 or later
- XcodeGen (`brew install xcodegen`), or create an equivalent SwiftUI iOS app manually using the settings in `project.yml`

## Generate and run

```sh
cd mapper-ios
xcodegen generate
open GnarlyMapper.xcodeproj
```

In Xcode, choose your development team and a physical LiDAR iPhone. The simulator cannot run RoomPlan scanning.

For the API origin, Cognito keys, and how publish works, see [FIREBASE_SETUP.md](FIREBASE_SETUP.md). The filename is historical. The mapper does not use a Firebase plist.

## Export behavior

The app writes each capture to its own sandboxed Documents folder:

```text
Documents/POCExports/<timestamp>-<zone-id>/
  manifest.json
  worldmap-zone-a.bin
  test-anchor.json
  scan.json
  scan-features.json
  building.json
  route.json                 if two or more nodes were recorded
  structure.usdz
  structure-metadata.json
```

Use the app’s share action to transfer that directory to the Unity engineer. Do not commit a real `ARWorldMap` to this repository.
