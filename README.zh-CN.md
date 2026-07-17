# Happy Oyster iOS SDK Demo

[English](README.md) | **简体中文**

这是 Happy Oyster iOS SDK 的 SwiftUI + CocoaPods 集成示例，覆盖创建世界、实时游玩和历史回看。

> 交付产品是 SDK。本示例中的业务接口调用、临时 API Key 管理和 UI 均由集成方实现，不属于 SDK 托管能力。

ScriptList、接口参数、会话状态、事件处理及内置组件说明见[详细接入指南](Example/docs/integration-guide.zh-CN.md)。

## 环境要求

- Xcode 15+
- iOS 15.0+
- CocoaPods
- 可访问三方服务端的模拟器或真机

## 快速开始

Android 与 iOS Demo 都依赖集成方的三方服务端。运行 App 前，先启动配套服务端 Demo（Node 或 Python），或启动以任意语言实现、提供兼容 `/server-api/*` 接口的自有三方服务端。主 API Key 只能保存在服务端，不得写入 App。

```bash
cd Example
pod install
open HappyOysterPodExample.xcworkspace
```

SDK 已发布到 CocoaPods 公开 Trunk，Podfile 里按版本号引入即可（见 `Example/Podfile`），无需任何本地 podspec 文件或文件夹。升级 SDK 版本时，把 Podfile 里的版本号改成新版本即可。

> 这是默认接入方式；无法访问 CocoaPods Trunk 的环境可改用本地路径依赖，见[详细接入指南「配置依赖」](Example/docs/integration-guide.zh-CN.md#2-配置依赖)。

模拟器可直接运行；真机运行需在 Xcode 中选择自己的开发者 Team，并授予麦克风权限。

## 首次运行配置

在 App 的「配置」Tab 填写：

- `三方服务端地址`：三方服务端的 scheme、host 和 port，例如 `http://192.168.1.23:3000`。不要追加 `/server-api`；App 会自行在该基地址后拼接 `/server-api/*`。
- `SDK API Host`：传给 `OysterConfig.apiHost` 的百炼 API Host。只填写控制台 API Key 页展示的裸 Host，不含 scheme 或 path；scheme 与 API path 由 SDK 内部补齐。

`SDK API Host` 必须与三方服务端使用的主 API Key 属于同一账号、同一地域，否则网关可能返回 `AccessDenied` 或 `401`。

## 鉴权与调用边界

主 API Key 保留在三方服务端。App 启动一次 Travel 所需的完整凭证组合为：

- **临时 API Key（token）**：由三方服务端签发给 App，短期有效，用于 SDK 运行态请求。
- **一次性 Travel ticket**：有效期 30 分钟，启动一次 Travel 时消费一次。

刷新临时 API Key 不需要重新换取 ticket。仅在启动另一段 Travel，或已有 ticket 未使用但已过期时，才需要获取新 ticket。

调用边界如下：

| 能力 | 调用方式 |
| --- | --- |
| 创建、查询、删除世界及查询历史和产物 | App 调用三方服务端 `/server-api/*` |
| 获取临时 API Key | App 调用 `/server-api/temp-api-key` |
| 获取一次性 Travel ticket | App 调用 `/server-api/travel-credential` |
| 实时音视频与互动 | App 使用临时 API Key，通过 SDK 直接调用 |

临时 API Key 的获取、缓存和续期由集成方负责。更新凭证：

```swift
HappyOysterEngine.shared.updateToken(<临时 API Key>)
```

SDK 返回 `101001`（tokenMissing）或 `101002`（tokenInvalid）时，应刷新临时 API Key、重新注入并重试。示例实现见 `Networking/TokenManager` 和 `TravelViewModel.sdkCall(_:)`。

## App 流程

1. 在「创建」Tab 创建 Adventure（`mode=1`，创建 UI 展示为 **Wander**）或 Directing（`mode=2`，创建 UI 展示为 **Story**）世界。
2. App 轮询世界构建状态，直到状态变为 `ready`。
3. 在「游玩」Tab 选择世界并获取一次性 Travel ticket。
4. SDK 创建并启动 Travel，进入实时音视频与互动。
5. 在「历史」Tab 查看已完成的 Travel 和视频产物。

Directing 支持简单描述和 ScriptList 两种创建方式。ScriptList 创建和 Travel 运行中更新都必须包含恰好 45 个 `acts`；更新只能由 App 调用三方服务端的 `POST /server-api/travels/update-script`，SDK 不直接调用该接口。模板和字段细节见详细指南及专门的接口文档。

## SDK 核心链路

```swift
HappyOysterEngine.shared.initialize(config: OysterConfig(
    apiHost: "<SDK 裸 Host>",
    logLevel: .info
))
HappyOysterEngine.shared.updateToken(temporaryAPIKey)

// 先从三方服务端获取一次性 ticket。
let travel = try HappyOysterEngine.shared.createTravel(ticket: ticket)

eventTask = Task {
    for await event in travel.events {
        // 处理状态与错误；必须在 start() 前订阅
    }
}

// 当前示例会传入配置的体验时长上限。
let data = try await travel.start(maxExperienceTimeSec: maxExperienceTimeSec)
// 挂载 OysterVideoView(travel:) 并发送互动指令
try await travel.end()
```

接入时注意：

- `travel.events` 必须在 `start()` 前订阅，避免遗漏早期事件。
- 同一时间只允许一个 active Travel；开始新会话前先结束旧会话。
- 主动退出、被动结束或失败时都必须收口调用一次幂等的 `end()`，及时释放远端资源。
- `pause()`、`resume()` 和 `rewind(toSec:)` 仅适用于返回版本为 `storyV2` 的 Directing 会话，并受当前状态限制。
- ARTC 依赖麦克风维持连接；需配置 `NSMicrophoneUsageDescription` 并获得权限。

SDK 内置 `OysterVideoView` 和 `WorldTravelControlsView`，集成方也可以替换为自己的渲染和操控 UI。

## 工程结构

```text
Example/
├── Podfile
├── HappyOysterPodExample.xcodeproj
└── HappyOysterPodExample/
    ├── App/             # Tab、导航与方向控制
    ├── Configuration/   # 地址配置与 SDK 初始化
    ├── Networking/      # 业务接口与临时 API Key 管理
    └── Features/        # 创建、游玩、历史和配置页面
```

业务接口字段以专门的接口文档为准；本工程只提供可运行的接入参考。
