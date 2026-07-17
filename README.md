# Happy Oyster iOS SDK Demo

**English** | [简体中文](README.zh-CN.md)

This SwiftUI + CocoaPods integration example for the Happy Oyster iOS SDK covers world creation, real-time play, and history review.

> The delivered product is the SDK. Business API calls, temporary API Key management, and UI in this example are implemented by the integrator and are not managed by the SDK.

See the [detailed integration guide](Example/docs/integration-guide.en.md) for ScriptList, API parameters, session states, event handling, and built-in components.

## Requirements

- Xcode 15+
- iOS 15.0+
- CocoaPods
- A simulator or device that can reach the third-party server

## Quick Start

Both the Android and iOS demos depend on the integrator's third-party server. Before running the app, start a server demo (Node or Python) or your own third-party server in any language that exposes compatible `/server-api/*` endpoints. The main API Key must remain on that server and must never be embedded in the app.

```bash
cd Example
pod install
open HappyOysterPodExample.xcworkspace
```

The SDK is published on the public CocoaPods Trunk, so the Podfile simply pins a version number (see `Example/Podfile`) — no local podspec file or folder is needed. To upgrade the SDK version, just bump the version number in the Podfile.

> This is the default path; if your environment can't reach the CocoaPods Trunk, use the local-path dependency instead — see ["Configure Dependencies" in the detailed integration guide](Example/docs/integration-guide.en.md#2-configure-dependencies).

The simulator runs without signing changes. For a physical device, select your developer team in Xcode and grant microphone permission.

## First-Run Configuration

Set these values on the app's Configuration tab:

- `Backend URL`: the scheme, host, and port of the third-party server, for example `http://192.168.1.23:3000`. Do **not** append `/server-api`; the app adds `/server-api/*` to this base URL.
- `SDK API Host`: Bailian API Host passed to `OysterConfig.apiHost`. Enter the bare host shown on the console API Key page, without a scheme or path; the SDK adds its scheme and API path internally.

`SDK API Host` must belong to the same account and region as the main API Key used by the third-party server; otherwise the gateway may return `AccessDenied` or `401`.

## Authentication and Call Boundary

The third-party server retains the main API Key. The complete app-side credential set for starting a Travel is:

- **Temporary API Key (token)**: issued to the app by the third-party server; short-lived and used for SDK runtime requests.
- **One-time Travel ticket**: valid for 30 minutes and consumed once when starting a Travel.

Refreshing the temporary API Key does not require exchanging for a new ticket. Obtain a new ticket only when starting another Travel or after the current ticket expires without being used.

| Capability | Call path |
| --- | --- |
| Create, query, or delete worlds; query history and artifacts | App calls third-party server `/server-api/*` |
| Obtain a temporary API Key | App calls `/server-api/temp-api-key` |
| Obtain a one-time Travel ticket | App calls `/server-api/travel-credential` |
| Real-time audio, video, and interaction | App calls through the SDK with a temporary API Key |

The integrator is responsible for obtaining, caching, and renewing the temporary API Key. Inject a refreshed credential with:

```swift
HappyOysterEngine.shared.updateToken(<temporary API Key>)
```

When the SDK returns `101001` (tokenMissing) or `101002` (tokenInvalid), refresh the temporary API Key, inject it again, and retry. See `Networking/TokenManager` and `TravelViewModel.sdkCall(_:)` for the example implementation.

## App Flow

1. Create an Adventure (`mode=1`, labeled **Wander** in the creation UI) or Directing (`mode=2`, labeled **Story** in the creation UI) world on the Create tab.
2. The app polls the build status until the world is `ready`.
3. Select a world on the Play tab and obtain a one-time Travel ticket.
4. The SDK creates and starts a Travel for real-time audio, video, and interaction.
5. Review completed Travels and video artifacts on the History tab.

Directing supports simple-description and ScriptList creation. Both ScriptList creation and in-progress updates require exactly 45 `acts`. Updates are performed only through the third-party server's `POST /server-api/travels/update-script`; the SDK does not call this endpoint directly. Refer to the detailed guide and dedicated API documentation for templates and field details.

## Core SDK Flow

```swift
HappyOysterEngine.shared.initialize(config: OysterConfig(
    apiHost: "<bare SDK API host>",
    logLevel: .info
))
HappyOysterEngine.shared.updateToken(temporaryAPIKey)

// Obtain a one-time ticket from the third-party server first.
let travel = try HappyOysterEngine.shared.createTravel(ticket: ticket)

eventTask = Task {
    for await event in travel.events {
        // Handle status and errors; subscribe before start()
    }
}

// The current example passes its configured experience limit.
let data = try await travel.start(maxExperienceTimeSec: maxExperienceTimeSec)
// Mount OysterVideoView(travel:) and send interaction commands
try await travel.end()
```

Integration requirements:

- Subscribe to `travel.events` before `start()` to avoid missing early events.
- Only one Travel may be active at a time; end the previous session before creating another.
- Funnel active exit, passive ending, and failure through one idempotent `end()` call to release remote resources.
- `pause()`, `resume()`, and `rewind(toSec:)` apply only to Directing sessions whose returned version is `storyV2`, and require the appropriate current state.
- ARTC requires microphone access to maintain the connection. Configure `NSMicrophoneUsageDescription` and obtain permission.

The SDK provides `OysterVideoView` and `WorldTravelControlsView`; integrators may replace them with custom rendering and control UI.

## Project Structure

```text
Example/
├── Podfile
├── HappyOysterPodExample.xcodeproj
└── HappyOysterPodExample/
    ├── App/             # tabs, navigation, and orientation
    ├── Configuration/   # endpoint settings and SDK initialization
    ├── Networking/      # business APIs and temporary API Key management
    └── Features/        # create, play, history, and configuration screens
```

The dedicated API documentation is the source of truth for business API fields; this project is a runnable integration reference.
