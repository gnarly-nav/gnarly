# Mapper cloud setup

The mapper lists buildings, loads published maps, and publishes scans through the HTTP API in `api/`. Sign-in is Cognito, the same user pool and public app client as the website. The app does not link the Firebase Apple SDK and does not read Firestore or Cloud Storage.

`GNARLY_BACKEND` on the API process still chooses AWS or Firebase for the server. This app always calls the HTTP API and sends a Cognito ID token on writes.

## Keys

Set these in `GnarlyMapper/Info.plist`. Empty values fall back to the live account.

| Key | Live value |
| --- | --- |
| `GnarlyApiBaseURL` | `https://m7sgp6qsjkimymyrwa6bilxqzq0acbhx.lambda-url.us-east-1.on.aws` |
| `CognitoUserPoolId` | `us-east-1_pQIUmVbPJ` |
| `CognitoClientId` | `1osnrt38iuqvf5laum1tnj1hdn` |
| `CognitoDomain` | `gnarly-naijei.auth.us-east-1.amazoncognito.com` |
| `CognitoRedirectURI` | `https://naijei.com/gnarly/` |

Use `http://127.0.0.1:8080` for `GnarlyApiBaseURL` only when the API is running on the same Mac. A device needs the https origin.

No `GoogleService-Info.plist` and no separate Google iOS client ID. Google is the Cognito hosted identity provider. The redirect above is already registered on the web app client, and iOS 17.4+ `ASWebAuthenticationSession` returns that https callback to the app.

## Sign-in and access

1. Run the mapper on an iPhone with iOS 17.4 or later. RoomPlan still needs a LiDAR device; the simulator can compile but cannot scan.
2. Tap **Sign in with Google**, or enter the email and password for an existing Cognito user. Google opens the hosted UI. Email uses the `USER_SRP_AUTH` challenge, the same one as the website, and does not create an account.
3. The ID token is stored in the Keychain and sent as `Authorization: Bearer` on API calls. The access token is not sent. It has no email claim.
4. Anyone signed in can list and open maps. Publish, placement, and layout saves succeed only for a verified address in `ADMIN_EMAILS` (default `nj277@cornell.edu`). Another account gets HTTP 403 from the API.

Sign-out clears the Keychain tokens on the phone. It does not open the hosted logout page.

## What a publish does

Upload asks `POST /v1/buildings/{id}/publishes` for signed PUT URLs, uploads each file, then `POST .../publishes/{id}/commit`. The active map changes only after commit. Creating a building is `POST /v1/buildings`. The library is `GET /v1/buildings`. Opening a building downloads `GET /v1/buildings/{id}/package` and then the signed file URLs. Saving the map pin is `PUT /v1/records`. Saving a layout on an existing version is a signed PUT plus `POST /v1/buildings/{id}/pointers`, the same pointer move the website uses.

Object keys stay `buildings/<id>/<version>/...`, including `worldmaps/<zoneId>.bin`.
