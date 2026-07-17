# Happy Oyster iOS SDK Detailed Integration Guide

**English** | [简体中文](integration-guide.zh-CN.md)

This guide describes the features, API boundaries, and session lifecycle of the Happy Oyster iOS SDK SwiftUI + CocoaPods example. See the [example README](../../README.md) for the quick-start instructions.

> **The delivered product is the SDK; this app is only an integration example.** All app-side logic demonstrated here (business API calls, temporary API Key lifecycle management, UI, etc.) is implemented by the **integrator**; the SDK does not take over these responsibilities.

This is a **complete, runnable example app** that shows how to integrate the SDK via CocoaPods and string together the core usage flow: **create a world → real-time play → history review**. Once you have the SDK, you can follow this project to quickly stand up a working integration environment.

---

## 1. Quick Start

### 1. Requirements

- Xcode 15+ / iOS 15.0+
- [CocoaPods](https://cocoapods.org)

### 2. Configure Dependencies

The SDK is distributed as precompiled binaries (xcframeworks), and can be added in either of the following ways:

| Path | When to use |
| --- | --- |
| [2.1 CocoaPods · Trunk version pin](#21-cocoapods--trunk-version-pin-default) | Regular integration; pin a version number and `pod install` downloads the binary automatically, no manual file management |
| [2.2 CocoaPods · local path](#22-cocoapods--local-path-no-network-access) | Environments without access to the CocoaPods Trunk, where the binary must be downloaded ahead of time |

This repository's `Example/Podfile` uses 2.1; see the relevant subsection below as needed.

#### 2.1 CocoaPods · Trunk version pin (default)

The SDK is published on the public CocoaPods Trunk (`https://cdn.cocoapods.org/`). Simply pin a version number, and CocoaPods downloads and unpacks the matching binary package automatically during `pod install`; no local file or folder dependency is involved:

```ruby
source 'https://cdn.cocoapods.org/'

platform :ios, '15.0'
use_frameworks!

target 'HappyOysterPodExample' do
  pod 'HappyOysterSDK', '1.0.3'               # aggregate entry (Core + World), one import and you're ready
  pod 'HappyOysterSDK/UI', '1.0.3'            # default UI components (video view, control HUD)
  pod 'HappyOysterSDK/StreamAliRTC', '1.0.3'  # video streaming + AliRTC engine adapter

  pod 'AliVCSDK_ARTC', '7.11.0'      # RTC vendor binary, weakly referenced, provided by the integrator, from the public CocoaPods source
end
```

> Notes
> - The SDK does not directly link/embed the RTC vendor binary (`AliVCSDK_ARTC`); the integrator must provide and import it.
> - `StreamAliRTC` already depends on `Stream`, so there is no need to declare it separately.
> - To upgrade the SDK version, change the three version numbers in the Podfile; run `pod trunk info HappyOysterSDK` to see the versions published on the Trunk.

#### 2.2 CocoaPods · local path (no network access)

References a copy of the xcframeworks + podspec already on local disk instead of downloading, useful for environments that cannot reach the CocoaPods Trunk.

1. Download the matching version's `HappyOysterSDK-xcframeworks.zip` from the [GitHub Release](https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases) and unzip it into any local directory (for example, a `Vendors/` folder next to this repository). The extracted directory should contain each `.xcframework`, `HappyOysterSDK.podspec`, and `LICENSE`.
2. Point the `Podfile` at that directory with `:path` (in `:path` mode CocoaPods reads the local files directly; the podspec's `s.source` field is not used, so it doesn't matter whether that download URL is reachable):

```ruby
target 'HappyOysterPodExample' do
  pod 'HappyOysterSDK', :path => '../Vendors'
  pod 'HappyOysterSDK/UI', :path => '../Vendors'
  pod 'HappyOysterSDK/StreamAliRTC', :path => '../Vendors'

  pod 'AliVCSDK_ARTC', '7.11.0'
end
```

> The `Vendors/` directory is not version-controlled (see `.gitignore`); each developer prepares it locally as needed.

### 3. Start the Third-Party Server

⚠️ **Both the Android and iOS demos require the integrator's third-party server; start it before running the app.** You can use the Node or Python server demo, or implement the compatible `/server-api/*` contract in any server-side language. The app does not hold the main API Key; obtaining a temporary API Key or Travel ticket and making **world-asset** requests such as creating a world all require the third-party server (see "6. Authentication and API Key Lifecycle"). Without it, the app cannot obtain credentials or create and manage worlds.

Start it according to the third-party server's own instructions, note the scheme / HOST / PORT it listens on, and fill them into the app's "Configuration" Tab later. The iOS example stores those three parts and forms a base URL such as `http://192.168.1.23:3000`; do not append `/server-api`, because each request path already includes `/server-api/*`.

### 4. Generate the Project and Run

```sh
cd Example

pod install                             # install dependencies
open HappyOysterPodExample.xcworkspace  # open the workspace (not the .xcodeproj)
```

It runs on the simulator out of the box; for a real device, select your own developer team in Xcode.

### 5. First-Run Configuration

The app connects to **two services** at the same time; fill these into the "Configuration" Tab before running:

| Configuration item | Description |
| --- | --- |
| Third-party server URL | The server demo or your own third-party server base URL, for example `http://192.168.1.23:3000`; the iOS app configures scheme / HOST / PORT separately and appends `/server-api/*` itself, so do not include `/server-api` here |
| SDK API Host | Bailian API Host used by the SDK for real-time audio/video access and injected into `OysterConfig.apiHost`; enter a bare host without a scheme or path, which the SDK adds internally |

`SDK API Host` must belong to the same account and region as the main API Key used by the third-party server; otherwise the gateway may return `AccessDenied` or `401`.

### 6. Authentication and API Key Lifecycle (Integrator's Responsibility)

The third-party server retains the **main API Key**: it is high-privilege and long-lived, and is **stored only on the integrator's third-party server and never delivered to the app**.

The complete app-side credential set for starting a Travel contains both:

- **Temporary API Key (token)**: issued to the app by the third-party server, short-lived, and used for SDK runtime authentication.
- **One-time Travel ticket**: issued by `/server-api/travel-credential`, valid for 30 minutes, and consumed once when starting a Travel.

Refreshing or replacing the temporary API Key does not require exchanging for another ticket. Request a new ticket only for another Travel, or when an unused ticket has expired.

Accordingly, APIs fall into two categories with different call paths:

| API category | Credential | How it's called |
| --- | --- | --- |
| **World-asset** (create/manage worlds, travel records and artifacts, etc.) | Backend authenticates with the **main API Key** | The app calls the third-party server's `/server-api/*` endpoints and **cannot connect directly** |
| **Play** (real-time audio/video, interaction, etc.) | Uses the **temporary API Key** | The app requests the capability directly via the **SDK**, **without going through the third-party server** |

**The temporary API Key lifecycle is managed by the integrator**; the SDK does not obtain or renew it. The integrator must request it from the third-party server, cache it, renew it near expiry, re-fetch it on authentication failure, and inject it through the SDK API:

```swift
HappyOysterEngine.shared.updateToken(<temporary API Key>)
```

This example provides a reference implementation under `Networking/` (`TokenManager`: caching + auto-renewal + re-fetch on failure) and exposes related settings in the "Configuration" Tab, which integrators can adapt into their own solution.

**Runtime handling of token invalidation**: the SDK throws error code `101001` (tokenMissing) / `101002` (tokenInvalid) when the token has expired or is invalid. You should catch both of these error codes uniformly at every SDK call site, refresh the token immediately, re-inject it, and retry — avoiding an interrupted user experience. The example's `TravelViewModel.sdkCall(_:)` shows one way to wrap this.

---

## 2. Feature Modules (by Tab)

The app has four Tabs: **Create / Play / History / Configuration**. The APIs below are all **world-asset** (forwarded through the third-party server; see "6. Authentication and API Key Lifecycle"). The API documentation governs the exact fields; this guide lists only the endpoints and main parameters used by the example.

### Create

Generate a new world, with two modes:

- **Adventure** (`mode=1`, labeled **Wander** in the creation UI): choose between the "first-frame image" or "scenario + role" sub-modes.
- **Directing** (`mode=2`, labeled **Story** in the creation UI): choose between the "simple description" or "structured script (scriptlist)" creation methods.
  - **Simple description (default)**: fill in the story background, with optional resolution and narrative style.
  - **Structured script (`creationModel=scriptlist`)**: submit a complete shot-by-shot script JSON (`scriptList`) plus a first-frame image URL directly, skipping AI script / first-frame generation. The UI provides a preset template dropdown to fill the editor in one tap, and performs local pre-validation before submitting (`synopsis` required, exactly 45 `acts` each with non-empty `content`, continuous non-duplicate `turn` values 1–45, at most 6 subjects, first-frame image must be a valid http(s) URL).

  **Template source and customization**: every template in the dropdown **comes from a local JSON file** `HappyOysterPodExample/scriptlist_presets.json` (bundled with the app as a resource). The linkage to the code is:

  ```text
  scriptlist_presets.json (bundle resource, the single source of truth for templates)
      └─ ScriptPreset.swift → ScriptPresetProvider.loadPresets() decodes it at startup
             (if the file is missing or fails to parse, falls back to the hardcoded
              "Midnight Visitor" template from the official API doc example)
          └─ MainView template dropdown → on selection, the entry's scriptList fills
             the editor and firstFrameImageUrl fills the first-frame URL field
  ```

  The file is an array; fields of each template entry:

  | Field | Required | Description |
  | --- | --- | --- |
  | `id` | Yes | Unique template identifier |
  | `name` | Yes | Display name in the dropdown (also backfills `synopsis`/`videoTitle` if missing in `scriptList`) |
  | `scenario` | No | Business scenario tag, shown as "name · scenario" in the dropdown |
  | `scriptList` | Yes | The complete script object (same structure as the API doc), strongly-typed validation at decode time |
  | `firstFrameImageUrl` | No | Filled into the first-frame URL field when the preset is selected |

  **To customize / add templates**: just add an entry with the structure above to that JSON file — no code changes needed (the file must stay in the target's Resources). Templates are validated against strongly-typed structs at decode time; a malformed field makes the whole file fall back to the built-in template, so run the app once after editing to confirm the dropdown contents. `ScriptPresetProvider.loadPresets()` is an async interface — to switch to server-delivered or user-created templates later, replace the data source inside that method and the UI stays untouched.

**API**: `POST /server-api/worlds` (async creation, `async = true`), returns `encryptedWorldId`.

**Main parameters**:

- Common: `mode` (1=Adventure / 2=Directing), `prompt` (world/story description, **required**; except for scriptlist).
- Adventure (creation UI: Wander): `perspective` (first/third person), `uploadMode` (`first_frame` / `scenario_role`); under `scenario_role`, pass the scene and role images and descriptions respectively (images are optional, at least one prompt field must be filled in).
- Directing (creation UI: Story, simple description): `resolution`, `narrative` (narrative style), etc.
- Directing (creation UI: Story, scriptlist): `creationModel="scriptlist"`, `resolution`, `firstFrameImage` (`{url}`), `scriptList` (the structured script object, passed through as-is). Note that scriptlist uses a **standalone parameter set**: simple-description parameters such as `prompt` / `narrative` must not be included, otherwise the server returns `400000`. See the API documentation for the field structure.

After creation, the UI polls `GET /server-api/worlds/build-status?encryptedWorldId=...` until `ready`, then automatically navigates to the "Play" Tab.

> **Reference images are an optional capability, passed through by URL**: the create API supports reference images (first-frame / scene / role), but **uploading and hosting the images requires the integrator to provide their own image service**; the API only accepts accessible image URLs. The example contains no upload logic and only demonstrates pass-through via a URL input field.

### Play

Displays created worlds in a grid, with filtering by mode, paginated loading, detail viewing, and deletion.

**APIs**:

- List: `GET /server-api/worlds` (`page` / `pageSize` / `mode` for pagination and filtering).
- Detail: `GET /server-api/worlds/detail?encryptedWorldId=...`. The response includes a `creationModel` field (`simple` / `scriptlist`), but **does not return** the full `scriptList` structure (it's only accepted at creation time, never read back); `prompt` is fixed to `null` for `scriptlist` worlds.
- Delete: `POST /server-api/worlds/delete`.

Tapping a **ready** world enters full-screen real-time play (landscape):

- **Adventure** (creation UI: Wander): dual-joystick HUD for real-time control.
- **Directing (simple description)** (creation UI: Story): a text input field to send storyline instructions; supports pause / resume / rewind.
- **Directing (scriptlist)** (creation UI: Story): the text instruct input is hidden (mutually exclusive with it), replaced by an "Update Script" entry — tapping it opens a panel with a preset dropdown, a full `scriptList` JSON editor, and a send button; sending **replaces the entire script** currently playing with the editor content. Whether the UI takes this branch is decided by `creationModel` (`simple` / `scriptlist`) fetched via a separate `GET /server-api/worlds/detail` call right after entering the session (the SDK's `start()` doesn't carry this field).

  **API**: `POST /server-api/travels/update-script` (`encryptedTravelId` + `scriptList`). Both creation and in-progress updates require **exactly 45 `acts`** with continuous turns 1–45. This is a world-asset request made only through the third-party server; the SDK does not call this endpoint directly.

Real-time play is a **play** API (direct SDK connection) and is the core SDK integration scenario; see "3. Core SDK Integration Flow (Play Session)" for the session lifecycle.

### History

Shows historical travel records, with filtering by status and pagination; opening a record lets you view its video artifact, played in portrait (video on top, artifact info and download entry on the bottom half).

**APIs**:

- List: `GET /server-api/travels` (`page` / `pageSize` / `status` for pagination and filtering).
- Artifacts: `GET /server-api/travels/artifacts?encryptedTravelId=...`, returns multiple video artifacts (`original` / `withWatermark` / `withInstruction` / `withInstructionAndWatermark`) for playback and download.

### Configuration

Demonstrates the integrator-side configuration capabilities (all example implementations, not SDK features):

- **Temporary API Key**: view the current credential and next auto-renewal time; manually "refresh now".
- **API Key settings**: validity period, auto-renewal toggle, and advance-renewal seconds used by `TokenManager`.
- **Server config / gateway URL**: modify the two URLs for the third-party server and the SDK gateway.
- **Reset SDK engine**: run `cleanup() → initialize() → re-inject the temporary API Key` to switch the gateway URL or troubleshoot. Not needed in normal use.

---

## 3. Core SDK Integration Flow (Play Session)

The play session is the part with the densest SDK usage; when integrating, focus on `TravelViewModel` / `TravelView`. The full lifecycle:

```text
① HappyOysterEngine.shared.initialize(config: OysterConfig(apiHost: <bare host>, ...))
     → the SDK adds the scheme and API path internally
② Obtain a temporary API Key from the third-party server, then call
     HappyOysterEngine.shared.updateToken(<temporary API Key>)
③ Exchange a one-time Travel ticket via the third-party server
     POST /server-api/travel-credential  body: { encryptedWorldId }
     → returns a 30-minute, one-time ticket (world-asset API, forwarded via the third-party server)
④ let travel = try HappyOysterEngine.shared.createTravel(ticket:)   // create an OysterTravel session handle
⑤ subscribe to travel.events                          // must subscribe before start to avoid missing events
⑥ let data = try await travel.start(maxExperienceTimeSec: limit)
     // the current example passes this argument; RTC join returns mode / version / encryptedTravelId
⑦ OysterVideoView(travel:)                            // render the remote picture (can be mounted after createTravel)
⑧ Real-time interaction:
     Adventure → travel.sendCommand(OysterAdventureCommand) // control command (fire-and-forget)
     Directing → try await travel.sendInstruct(content:)     // text storyline instruction
⑨ Pause / rewind (Directing with storyV2 only, see below): travel.pause() / resume() / rewind(toSec:)
     // rewind(toSec:) takes a target time point in seconds (must be >= 1); playback resumes automatically after rewinding
     // the return value resumedAtSec is the actual resume time point on the server, useful for correcting local timing
⑩ try await travel.end()                              // end play, release remote resources (be sure to call)
```

> The session operations in steps ⑧–⑩ (interaction / pause / resume / rewind / end) are all **play capabilities, requested directly by the SDK without going through the third-party server**. Script updates are the exception described above: they use the third-party server endpoint, not an SDK method. See the SDK reference for exact method signatures and return models.

> ⚠️ **Always call `travel.end()` once when ending play**: whether the user exits actively or the session ends passively (timer expiry, receiving `.ended` / `.failed`, page destruction, etc.), make sure a single `end()` is reached. Otherwise the remote RTC / session resources may not be released promptly. It is recommended to funnel all exit paths into the same cleanup method (the example's `endAndDismiss()` is designed for this) and make it idempotent to avoid duplicate calls.

### Event Subscription and Handling

`travel.events` is an `AsyncStream<OysterTravelEvent>`; **be sure to subscribe before `start()`** to avoid missing early statuses. There are two kinds of events: `.statusChanged(OysterTravelStatus)` and `.error(OysterSDKError)`.

```swift
eventTask = Task {
    for await event in travel.events {
        switch event {
        case .statusChanged(let status):
            handleStatusChange(status)
        case .error(let error):
            // record error info for the UI; fatal errors are surfaced separately via status → .failed
            handleSDKError(error)
        @unknown default:
            break
        }
    }
}
```

`OysterTravelStatus` has seven states; the UI just follows it (`ended` / `failed` are terminal):

| Status | Meaning | Typical handling |
| --- | --- | --- |
| `idle` | after create, before start | — |
| `prepare` | connecting / reconnecting (first time = connecting, after playing = reconnecting) | show connecting / reconnecting hint |
| `running` | stream ready, interactive | show picture and controls, start the timer |
| `pausing` | pause accepted, awaiting server confirmation | show "pausing…" |
| `paused` | paused (confirmed) | show paused state (eligible Directing sessions can rewind) |
| `ended` | ended (terminal) | **call `travel.end()` to wrap up and close the page** |
| `failed` | failed (terminal) | show error, **call `travel.end()` to wrap up** |

Handling points:

- **Errors come in two kinds**: `.error` events are for recording / display; **fatal errors are actively terminated by the SDK and surfaced via `status → .failed`**, so the app side need not judge fatality itself and can wrap up uniformly in the `.failed` branch.
- After entering `ended` / `failed`, the session has terminated and all session operations (pause/resume/sendCommand…) no longer take effect.

### Built-in SDK Components (Replaceable)

This example uses the SDK's built-in UI components directly; integrators may also replace them with their own:

| Component | Source | Purpose |
| --- | --- | --- |
| `OysterVideoView(travel:)` | `HappyOysterSDK` | Remote picture rendering view, bound to an `OysterTravel` session |
| `WorldTravelControlsView` | `HappyOysterUI` | Adventure-mode default dual-joystick + button HUD, callback produces `WorldControlParams` |

- **Rendering**: `OysterVideoView(travel:)` is the rendering entry; it can be mounted into any hierarchy after `createTravel`, before or after `start()`. The example only shows it after `start()` succeeds, which is **a conservative strategy to avoid a zero-sized view under full-screen layout, not a hard SDK requirement**.
- **Control**: the example uses the built-in `WorldTravelControlsView`, whose `WorldControlParams` callback is bridged via the `OysterAdventureCommand(_:)` convenience init and then sent with `sendCommand`. Integrators can **replace it with their own control UI** — just construct `OysterAdventureCommand` (`translation` / `rotation` / `interaction`) and send it.
- **Command throttling**: `sendCommand` is fire-and-forget; **external input can be high-frequency every frame, and the SDK throttles internally** (latest-wins sampling, frame merging at RTC line rate), keeping the frequency sent to the remote under control, so the host does not need to throttle itself. Note that **the server's response to commands itself has latency, so the actual effective time is not fixed** — do not assume immediate effect.
- **Action list (Adventure, WanderV2 version)**: the available character / environment actions are delivered via `characterActions` / `environmentActions` (string lists in the Travel state details); integrators render custom control items accordingly and assemble the actions to send. See the SDK reference for exact fields and the sending method.

### Preconditions for Pause / Rewind

`pause()` / `resume()` / `rewind(toSec:)` are **not available for all Directing** worlds; there is version and state gating (otherwise it synchronously throws `invalidState` / 103002):

- **Version**: only supported when `travelVersion == "storyV2"` returned by `start()`; other versions and Adventure mode do not support it.
- **State**: `pause()` requires the current state to be `running`; `resume()` requires `paused`; `rewind(toSec:)` requires the current state to be `paused`.
- **Rewind range**: pass the target time point in seconds, which must be >= 1. Playback resumes automatically after rewinding; the return value `resumedAtSec` is the actual resume time point on the server, useful for correcting local timing.

Integrators should decide whether to show pause / rewind entries based on `travelVersion`, and only allow triggering them in the corresponding state.

### Other Integration Notes

- **Only one active Travel at a time**: calling `HappyOysterEngine.createTravel` again before the previous `OysterTravel` has `end()`ed synchronously throws `concurrentTravel` (103004). Be sure to end the old session before opening a new one.
- **Session-handle-style API**: pause / resume / rewind / interact / end are all invoked on the `OysterTravel` instance.
- **Always call `end()` on exit**: funnel active / passive endings into the same idempotent cleanup method to ensure remote resources are released promptly (see lifecycle ⑩ above).
- **ARTC strongly depends on the microphone**: RTC uses local audio capture to keep the DataChannel alive; **no usable audio input causes RTC connection to fail**. Configure `NSMicrophoneUsageDescription` in `Info.plist` and ensure microphone permission is granted; on a physical device, also make sure a microphone is available.
- The SDK is initialized only once: `HappyOysterEngine.shared.initialize(config:)`, which internally completes stream engine registration (runtime discovery); the host only needs `import HappyOysterSDK` and does not need to care about the vendor / engine selection.
- SDK logs can be wired into the app's own logging system via `OysterLog.setHandler` (the example bridges to `os.Logger`).

---

## 4. Project Structure

```text
Example/
├── Podfile                              # CocoaPods dependencies
├── HappyOysterSDK.podspec               # SDK binary distribution podspec (s.source points at the GitHub Release)
├── LICENSE                              # LICENSE for the SDK binaries (referenced by the podspec)
├── HappyOysterPodExample.xcodeproj
└── HappyOysterPodExample/
    ├── HappyOysterPodExampleApp.swift   # @main: SDK log takeover + initialization entry
    ├── App/                             # Tab container, navigation, orientation locking
    ├── Configuration/                   # environment config (service URLs / API Key settings), SDK initialization wrapper
    ├── Networking/                      # business API client (URLSession + async/await), temporary API Key lifecycle reference
    └── Features/
        ├── Main/         # Create
        ├── Secondary/    # Play (includes TravelView / TravelViewModel —— the SDK session core)
        ├── History/      # History
        └── Profile/      # Configuration
```

> The request/response fields of the business APIs (worlds / travels, etc.) are governed by the **dedicated API documentation**; this project's `Networking/` is only a runnable example.

---

## 5. Notes

- The delivered product is the SDK; this app's business APIs, AK management, UI, etc. are all **integrator-side reference implementations** and can be replaced as needed.
- The request/response fields of the business APIs (worlds / travels, etc.) are governed by the **dedicated API documentation**.
- `Pods/` and `*.xcworkspace` are generated by `pod install` and are not under version control.
- This example references only public subspecs and can serve as a reference sample for external integration.
