# Happy Oyster iOS SDK 详细接入指南

[English](integration-guide.en.md) | **简体中文**

本文详细说明 Happy Oyster iOS SDK SwiftUI + CocoaPods 示例中的功能、接口边界与会话生命周期。快速运行步骤见[示例 README](../../README.zh-CN.md)。

> **交付产品是 SDK，本 App 只是集成示例。** 这里演示的所有 App 侧逻辑（业务接口调用、临时 API Key 生命周期管理、UI 等）都属于**集成方自行实现**的范畴，SDK 不代管这些职责；本工程提供一套可直接参考的实现方式。

这是一个**可直接运行的完整示例 App**，演示如何用 CocoaPods 集成 SDK，并串起核心使用链路：**创建世界 → 实时游玩 → 历史回看**。拿到 SDK 后，照着这个工程即可快速搭出一套可跑的接入环境。

---

## 一、快速开始

### 1. 环境要求

- Xcode 15+ / iOS 15.0+
- [CocoaPods](https://cocoapods.org)

### 2. 配置依赖

SDK 以预编译二进制（xcframework）分发，支持以下两种引入方式：

| 方式 | 适用场景 |
| --- | --- |
| [2.1 CocoaPods · Trunk 版本引入](#21-cocoapods--trunk-版本引入默认方式) | 常规集成，按版本号引入，`pod install` 自动联网下载二进制，无需手动管理任何文件 |
| [2.2 CocoaPods · 本地路径](#22-cocoapods--本地路径无网络环境) | 无法访问 CocoaPods Trunk 的环境，二进制需提前下载到本地 |

本仓库的 `Example/Podfile` 使用 2.1；下面按需查看对应小节。

#### 2.1 CocoaPods · Trunk 版本引入（默认方式）

SDK 已发布到 CocoaPods 公开 Trunk（`https://cdn.cocoapods.org/`），按版本号引入即可，`pod install` 时由 CocoaPods 自动下载解压对应版本的二进制包，不依赖任何本地文件或文件夹：

```ruby
source 'https://cdn.cocoapods.org/'

platform :ios, '15.0'
use_frameworks!

target 'HappyOysterPodExample' do
  pod 'HappyOysterSDK', '1.0.3'               # 聚合入口（Core + World），import 一行即用
  pod 'HappyOysterSDK/UI', '1.0.3'            # 默认 UI 组件（视频视图、操控 HUD）
  pod 'HappyOysterSDK/StreamAliRTC', '1.0.3'  # 视频流 + AliRTC 引擎适配器

  pod 'AliVCSDK_ARTC', '7.11.0'      # RTC 厂商二进制，弱引用，由集成方提供，来自 CocoaPods 公开源
end
```

> 说明
> - SDK 不直接链接/嵌入 RTC 厂商二进制（`AliVCSDK_ARTC`），需集成方自行提供并引入。
> - `StreamAliRTC` 已依赖 `Stream`，无需单独声明。
> - 升级 SDK 版本时，把 Podfile 里三处版本号改成新版本即可；可用 `pod trunk info HappyOysterSDK` 查看 Trunk 上已发布的版本列表。

#### 2.2 CocoaPods · 本地路径（无网络环境）

不联网下载、直接引用本地磁盘上的一份 xcframework + podspec，适合无法访问 CocoaPods Trunk 的环境。

1. 从 [GitHub Release](https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases) 下载对应版本的 `HappyOysterSDK-xcframeworks.zip` 并解压到本地任意目录（例如仓库同级的 `Vendors/`），解压后目录下应有各 `.xcframework`、`HappyOysterSDK.podspec`、`LICENSE`。
2. `Podfile` 改用 `:path` 指向该目录（`:path` 模式下 CocoaPods 直接读取本地文件，podspec 里的 `s.source` 字段不会被用到，因此无需关心其中的下载地址是否可达）：

```ruby
target 'HappyOysterPodExample' do
  pod 'HappyOysterSDK', :path => '../Vendors'
  pod 'HappyOysterSDK/UI', :path => '../Vendors'
  pod 'HappyOysterSDK/StreamAliRTC', :path => '../Vendors'

  pod 'AliVCSDK_ARTC', '7.11.0'
end
```

> `Vendors/` 目录不纳入版本管理（见 `.gitignore`），每个开发者按需在本机自行准备。

### 3. 启动三方服务端

⚠️ **Android 与 iOS Demo 都依赖集成方的三方服务端，运行 App 前必须先启动它。** 可选用 Node 或 Python 服务端 Demo，也可使用任意服务端语言实现兼容的 `/server-api/*` 协议。App 自身不持有主 API Key；临时 API Key、Travel ticket 的获取以及创建世界等**世界资产类**请求都要经过三方服务端（见[鉴权小节](#6-鉴权与-api-key-生命周期集成方职责)）。服务未启动时，App 无法获取凭证，创建和管理世界等功能也会失败。

按三方服务端自身的说明启动它，记下其监听的 scheme / HOST / PORT，稍后在 App「配置」Tab 填入。iOS 示例分别保存这三项并组合成 `http://192.168.1.23:3000` 这样的基地址；不要追加 `/server-api`，因为每个请求 path 已包含 `/server-api/*`。

### 4. 生成工程并运行

```sh
cd Example

pod install                             # 安装依赖
open HappyOysterPodExample.xcworkspace  # 打开 workspace（不是 .xcodeproj）
```

模拟器可直接运行；真机运行需在 Xcode 里选择自己的开发者 Team。

### 5. 首次运行配置

App 同时对接**两个服务**，运行前在「配置」Tab 填好：

| 配置项 | 说明 |
| --- | --- |
| 三方服务端地址 | 服务端 Demo 或自有三方服务端的基地址，例如 `http://192.168.1.23:3000`；iOS App 分别配置 scheme / HOST / PORT，并自行追加 `/server-api/*`，因此这里不要包含 `/server-api` |
| SDK API Host | SDK 实时音视频接入的百炼 API Host，注入到 `OysterConfig.apiHost`；只填写裸 Host，不含 scheme 或 path，二者由 SDK 内部补齐 |

`SDK API Host` 必须与三方服务端使用的主 API Key 属于同一账号、同一地域，否则网关可能返回 `AccessDenied` 或 `401`。

### 6. 鉴权与 API Key 生命周期（集成方职责）

三方服务端保留**主 API Key**：它权限高、长期有效，**只能保存在集成方三方服务端，绝不能下发到 App**。

App 启动一次 Travel 所需的完整凭证组合同时包含：

- **临时 API Key（token）**：由三方服务端签发，短期有效。App 向三方服务端请求获取，用于 SDK 运行态能力鉴权。
- **一次性 Travel ticket**：由 `/server-api/travel-credential` 签发，有效期 30 分钟，启动一次 Travel 时消费一次。

刷新或替换临时 API Key 不需要重新换取 ticket。仅在启动另一段 Travel，或已有 ticket 未使用但已过期时，才请求新 ticket。

据此，接口分为两类，调用路径不同：

| 接口类型 | 凭证 | 调用方式 |
| --- | --- | --- |
| **世界资产类**（创建 / 管理世界、旅途记录与产物等） | 服务端使用**主 API Key**鉴权 | App **不能直连**，通过三方服务端的 `/server-api/*` 请求 |
| **游玩类**（实时音视频、互动等） | 使用**临时 API Key** | App 通过 **SDK** 直接请求对应能力，**无需经三方服务端转发** |

**临时 API Key 的生命周期由集成方自行管理**，SDK 不负责获取或续期。集成方需要自己实现：向三方服务端请求临时 API Key、缓存、临近过期时续期、鉴权失败时重取，并通过 SDK 接口注入：

```swift
HappyOysterEngine.shared.updateToken(<临时 API Key>)
```

本示例在 `Networking/` 下给出了一份参考实现（`TokenManager`：缓存 + 自动续期 + 失败重取），并在「配置」Tab 暴露了相关设置，集成方可据此改造为自己的方案。

**Token 失效的运行时处理**：SDK 在 token 过期或无效时会抛出错误码 `101001`（tokenMissing）/ `101002`（tokenInvalid）。应在所有 SDK 调用处统一捕获这两个错误码，立即刷新 token 并重新注入后重试，避免打断用户体验。示例的 `TravelViewModel.sdkCall(_:)` 给出了封装方式。

---

## 二、功能模块（按 Tab）

App 为四个 Tab：**创建 / 游玩 / 历史 / 配置**。下列接口均属**世界资产类**（走三方服务端转发，见[鉴权小节](#6-鉴权与-api-key-生命周期集成方职责)）；具体字段以接口文档为准，这里只列示例用到的端点与主要传参。

### 创建

生成一个新世界，支持两种模式：

- **Adventure**（`mode=1`，创建 UI 展示为 **Wander**）：可选「首帧图」或「场景角色」两种子模式。
- **Directing**（`mode=2`，创建 UI 展示为 **Story**）：可选「简单描述」或「结构化剧本 scriptlist」两种创建方式。
  - **简单描述（默认）**：填写故事背景，可选分辨率、叙事风格。
  - **结构化剧本（`creationModel=scriptlist`）**：直接提交完整分镜剧本 JSON（`scriptList`）与首帧图 URL，跳过 AI 剧本 / 首帧生成。界面提供预置模板下拉一键填入编辑器，提交前做本地预校验（`synopsis` 必填、`acts` 必须恰好 45 条且每拍 `content` 非空、`turn` 按 1–45 连续且不重复、角色最多 6 个、首帧图需合法 http(s) URL）。

  **模板来源与自定义**：下拉框中的模板**全部来自本地 JSON 文件** `HappyOysterPodExample/scriptlist_presets.json`（随 App 打包为 Bundle 资源），与代码的关联链路是：

  ```text
  scriptlist_presets.json（Bundle 资源，模板的唯一事实源）
      └─ ScriptPreset.swift → ScriptPresetProvider.loadPresets() 启动时解码
             （文件缺失/解析失败时回落代码内置兜底「午夜访客」，出自接口文档官方示例）
          └─ MainView 模板下拉框 → 选中后把该条 scriptList 灌入编辑器、
             firstFrameImageUrl 灌入首帧图输入框
  ```

  文件是一个数组，每条模板的字段：

  | 字段 | 必填 | 说明 |
  | --- | --- | --- |
  | `id` | 是 | 模板唯一标识 |
  | `name` | 是 | 下拉框展示名（`scriptList` 缺 `synopsis`/`videoTitle` 时兜底填充） |
  | `scenario` | 否 | 业务场景标签，下拉框展示为「名称 · 场景」 |
  | `scriptList` | 是 | 完整剧本对象（结构同接口文档），解析期做强类型校验 |
  | `firstFrameImageUrl` | 否 | 选中模板时同步填入首帧图输入框 |

  **想自定义 / 新增模板**：直接在该 JSON 文件里加一条上述结构的记录即可，无需改代码（文件需保留在 target 的 Resources 中）。模板在解码期按强类型结构校验，字段写错会整体回落兜底模板，改完建议跑一次 App 确认下拉框内容。`ScriptPresetProvider.loadPresets()` 是异步接口，后续如需改为服务端下发 / 用户自建模板，替换该方法的数据源即可，UI 无需改动。

**调用接口**：`POST /server-api/worlds`（异步创建，`async = true`），返回 `encryptedWorldId`。

**主要传参**：

- 通用：`mode`（1=Adventure / 2=Directing）、`prompt`（世界 / 故事描述，**必填**；scriptlist 除外）。
- Adventure（创建 UI：Wander）：`perspective`（第一 / 第三人称）、`uploadMode`（`first_frame` / `scenario_role`）；`scenario_role` 下分别传场景、角色的图片与描述（图片可选，至少填写一项 prompt）。
- Directing（创建 UI：Story，简单描述）：`resolution`、`narrative`（叙事风格）等。
- Directing（创建 UI：Story，scriptlist）：`creationModel="scriptlist"`、`resolution`、`firstFrameImage`（`{url}`）、`scriptList`（结构化剧本对象，原样透传）。注意 scriptlist 是**独立参数集**，不可携带 `prompt` / `narrative` 等简单描述参数，否则服务端返回 `400000`。字段结构见接口文档。

创建后界面轮询 `GET /server-api/worlds/build-status?encryptedWorldId=...` 直到 `ready`，随后自动跳转「游玩」Tab。

> **参考图为可选能力，通过 URL 透传**：创建接口支持传入参考图（首帧图 / 场景图 / 角色图），但**图片的上传与托管需集成方提供自己的图像服务**，接口只接收可访问的图片 URL。示例不含上传逻辑，仅以 URL 输入框演示透传。

### 游玩

以网格展示已创建的世界，支持按模式筛选、分页加载、查看详情、删除。

**调用接口**：

- 列表：`GET /server-api/worlds`（`page` / `pageSize` / `mode` 分页筛选）。
- 详情：`GET /server-api/worlds/detail?encryptedWorldId=...`。响应带 `creationModel` 字段（`simple` / `scriptlist`），但**不返回**完整 `scriptList` 结构（该字段仅创建时提交，接口不回读）；`scriptlist` 世界的 `prompt` 固定为 `null`。
- 删除：`POST /server-api/worlds/delete`。

点击**已就绪**的世界即进入全屏实时游玩（横屏）：

- **Adventure**（创建 UI：Wander）：双摇杆 HUD 实时操控。
- **Directing（简单描述）**（创建 UI：Story）：文本输入框发送剧情指令；支持暂停 / 恢复 / 回溯。
- **Directing（scriptlist）**（创建 UI：Story）：不展示文本指令输入框（与之互斥），改为「更新剧本」入口——点开后提供模板下拉、完整 scriptList JSON 编辑器和发送按钮，点击发送即用编辑器内容**整体替换**当前正在播放的剧本。UI 是否走这条分支由进入会话后单独请求 `GET /server-api/worlds/detail` 拿到的 `creationModel`（`simple` / `scriptlist`）决定（SDK 的 `start()` 不带该字段）。

  **调用接口**：`POST /server-api/travels/update-script`（`encryptedTravelId` + `scriptList`）。创建和运行中更新都要求**恰好 45 个 `acts`**，且 `turn` 按 1–45 连续。这是只能通过三方服务端发起的世界资产类请求；SDK 不直接调用该接口。

实时游玩属**游玩类**接口（走 SDK 直连），是 SDK 集成的核心场景，会话生命周期见 [第三节](#三sdk-集成核心链路游玩会话)。

### 历史

展示历史旅途记录，支持按状态筛选、分页；进入某条记录可查看其视频产物，竖屏播放（视频占上半，下半展示产物信息与下载入口）。

**调用接口**：

- 列表：`GET /server-api/travels`（`page` / `pageSize` / `status` 分页筛选）。
- 产物：`GET /server-api/travels/artifacts?encryptedTravelId=...`，返回多路视频产物（`original` / `withWatermark` / `withInstruction` / `withInstructionAndWatermark`）供播放与下载。

### 配置

演示集成方侧的配置能力（均为示例实现，非 SDK 功能）：

- **临时 API Key**：查看当前凭证、下次自动续期时间，可手动「立即刷新」。
- **API Key 设置**：有效期、自动续期开关、提前续期秒数（驱动示例的 `TokenManager`）。
- **服务器配置 / 网关地址**：修改三方服务端与 SDK 网关两个地址。
- **重置 SDK 引擎**：依次 `cleanup() → initialize() → 重新注入临时 API Key`，用于切换网关地址或排查问题。正常使用无需执行。

---

## 三、SDK 集成核心链路（游玩会话）

游玩会话是 SDK 调用最密集的部分，集成时重点参考 `TravelViewModel` / `TravelView`。完整生命周期：

```text
① HappyOysterEngine.shared.initialize(config: OysterConfig(apiHost: <裸 Host>, ...))
     → scheme 与 API path 由 SDK 内部补齐
② 从三方服务端获取临时 API Key，再调用
     HappyOysterEngine.shared.updateToken(<临时 API Key>)
③ 向三方服务端换取一次性 Travel ticket
     POST /server-api/travel-credential  body: { encryptedWorldId }
     → 返回有效期 30 分钟的一次性 ticket（世界资产类接口，走三方服务端转发）
④ let travel = try HappyOysterEngine.shared.createTravel(ticket:)   // 创建 OysterTravel 会话句柄
⑤ 订阅 travel.events                                 // 必须在 start 前订阅，避免漏事件
⑥ let data = try await travel.start(maxExperienceTimeSec: limit)
     // 当前示例传入该参数；RTC 入会后返回 mode / version / encryptedTravelId
⑦ OysterVideoView(travel:)                           // 渲染远端画面（createTravel 后即可挂载）
⑧ 实时互动：
     Adventure → travel.sendCommand(OysterAdventureCommand) // 操控指令（fire-and-forget）
     Directing → try await travel.sendInstruct(content:)     // 文本剧情指令
⑨ 暂停 / 回溯（仅返回 storyV2 的 Directing 会话，见下）：travel.pause() / resume() / rewind(toSec:)
     // rewind(toSec:) 传入目标时间点（秒，不得小于 1）；回溯后会话自动恢复播放
     // 返回值 resumedAtSec 为服务端实际恢复时间点，可用于校正本地计时
⑩ try await travel.end()                             // 结束游玩，释放远端资源（务必调用）
```

> 第 ⑧–⑩ 步的会话操作（互动 / 暂停 / 恢复 / 回溯 / 结束）都是**游玩类能力，由 SDK 直接请求，无需经三方服务端转发**。更新剧本是上文说明的例外：它调用三方服务端接口，不是 SDK 方法。具体方法签名与返回模型见 SDK 接口。

> ⚠️ **结束游玩务必调用一次 `travel.end()`**：无论是用户主动退出，还是会话被动结束（计时到期、收到 `.ended` / `.failed`、页面销毁等），都要确保走到一次 `end()`。否则远端 RTC / 会话资源可能无法及时释放。建议把所有退出路径收口到同一个清理方法里（示例的 `endAndDismiss()` 即为此设计），并做好幂等，避免重复调用。

### 事件监听与处理

`travel.events` 是一个 `AsyncStream<OysterTravelEvent>`，**务必在 `start()` 之前订阅**，避免漏掉早期状态。事件有两类：`.statusChanged(OysterTravelStatus)` 与 `.error(OysterSDKError)`。

```swift
eventTask = Task {
    for await event in travel.events {
        switch event {
        case .statusChanged(let status):
            handleStatusChange(status)
        case .error(let error):
            // 记录错误信息供 UI 展示；致命错误会另行经 status → .failed 透出
            handleSDKError(error)
        @unknown default:
            break
        }
    }
}
```

`OysterTravelStatus` 共七态，UI 跟随它变化即可（`ended` / `failed` 为终态）：

| 状态 | 含义 | 典型处理 |
| --- | --- | --- |
| `idle` | create 后、start 前 | — |
| `prepare` | 建连 / 重连中（首次=连接中，已游玩后=重连中） | 展示连接 / 重连提示 |
| `running` | 流就绪、可交互 | 显示画面与操控、启动计时 |
| `pausing` | 暂停已受理、等待服务端确认 | 展示「暂停中…」 |
| `paused` | 已暂停（确认） | 展示暂停态（符合条件的 Directing 会话可回溯） |
| `ended` | 已结束（终态） | **调用 `travel.end()` 收尾并关闭页面** |
| `failed` | 失败（终态） | 展示错误，**调用 `travel.end()` 收尾** |

处理要点：

- **错误分两类**：`.error` 事件用于记录 / 展示；**致命错误由 SDK 主动终止会话并经 `status → .failed` 透出**，App 侧不必自行判定致命性，统一在 `.failed` 分支收尾即可。
- 进入 `ended` / `failed` 后会话已终止，所有会话操作（pause/resume/sendCommand…）都不再生效。

### SDK 内置组件（可替换）

本示例直接使用 SDK 提供的内置 UI 组件，集成方也可替换为自有组件：

| 组件 | 来源 | 作用 |
| --- | --- | --- |
| `OysterVideoView(travel:)` | `HappyOysterSDK` | 远端画面渲染视图，绑定到 `OysterTravel` 会话 |
| `WorldTravelControlsView` | `HappyOysterUI` | Adventure 模式默认双摇杆 + 按键 HUD，回调产出 `WorldControlParams` |

- **渲染**：`OysterVideoView(travel:)` 是渲染入口，`createTravel` 之后即可挂入任意层级，`start()` 前后挂载都可以。示例之所以等 `start()` 成功后才显示，只是**为规避全屏布局下视图尺寸为 0 的保守策略，并非 SDK 的硬性要求**。
- **操控**：示例用内置 `WorldTravelControlsView`，其回调 `WorldControlParams` 经 `OysterAdventureCommand(_:)` 便捷 init 桥接后 `sendCommand` 下发。集成方可**替换为自有操控 UI**——直接构造 `OysterAdventureCommand`（`translation` / `rotation` / `interaction`）发送即可。
- **指令节流**：`sendCommand` 是 fire-and-forget，**外部可每帧高频持续输入，SDK 内部会做节流**（latest-wins 采样，按 RTC 线速合帧），保证发往远端的频率受控，宿主无需自行节流。注意**服务端对指令的响应本身有延迟，实际生效时间并不固定**，不要假设即时生效。
- **动作清单（Adventure，WanderV2 版本）**：可用的角色 / 环境动作以 `characterActions` / `environmentActions`（Travel 状态明细里的字符串列表）下发，集成方据此渲染自定义操控项并组织要发送的操作内容。具体字段与发送方式请读 SDK 接口。

### 暂停 / 回溯的前置条件

`pause()` / `resume()` / `rewind(toSec:)` **并非所有 Directing 都可用**，有版本与状态门控（不满足会同步抛 `invalidState` / 103002）：

- **版本**：仅 `start()` 返回的 `travelVersion == "storyV2"` 才支持；其它版本及 Adventure 模式不支持。
- **状态**：`pause()` 要求当前 `running`；`resume()` 要求 `paused`；`rewind(toSec:)` 要求当前处于 `paused`。
- **回溯范围**：传入目标时间点（秒），不得小于 1。回溯后会话自动恢复播放，返回值 `resumedAtSec` 为服务端实际恢复时间点，可用于校正本地计时。

集成方应据 `travelVersion` 决定是否展示暂停 / 回溯入口，并在对应状态下才允许触发。

### 其它集成要点

- **同一时间只允许一个 active Travel**：`HappyOysterEngine.createTravel` 在上一个 `OysterTravel` 未 `end()` 前再次调用，会同步抛 `concurrentTravel`（103004）。开新会话前务必先结束旧会话。
- **会话句柄式 API**：暂停 / 恢复 / 回溯 / 互动 / 结束都打在 `OysterTravel` 实例上。
- **退出必调 `end()`**：主动 / 被动结束都收口到同一个幂等清理方法，确保远端资源及时释放（详见上方生命周期 ⑩）。
- **ARTC 强依赖麦克风**：RTC 用本地音频采集维持 DataChannel 保活，**没有可用的音频输入会导致 RTC 建连失败**。需在 `Info.plist` 配置 `NSMicrophoneUsageDescription` 并确保已获麦克风权限；真机运行也要保证有麦克风可用。
- SDK 初始化只需一次：`HappyOysterEngine.shared.initialize(config:)`，内部自动完成流引擎注册（运行期发现），宿主只 `import HappyOysterSDK` 即可，无需关心厂商 / 引擎选择。
- SDK 日志可通过 `OysterLog.setHandler` 接到 App 自有日志系统（示例桥接到 `os.Logger`）。

---

## 四、工程结构

```text
Example/
├── Podfile                              # CocoaPods 依赖
├── HappyOysterSDK.podspec               # SDK 二进制分发 podspec（s.source 指向 GitHub Release）
├── LICENSE                              # SDK 二进制的 LICENSE（podspec 引用）
├── HappyOysterPodExample.xcodeproj
└── HappyOysterPodExample/
    ├── HappyOysterPodExampleApp.swift   # @main：SDK 日志接管 + 初始化入口
    ├── App/                             # Tab 容器、导航、方向锁定
    ├── Configuration/                   # 环境配置（服务地址 / API Key 设置）、SDK 初始化封装
    ├── Networking/                      # 业务接口客户端（URLSession + async/await）、临时 API Key 生命周期参考实现
    └── Features/
        ├── Main/         # 创建
        ├── Secondary/    # 游玩（含 TravelView / TravelViewModel —— SDK 会话核心）
        ├── History/      # 历史
        └── Profile/      # 配置
```

> 业务接口（世界 / 旅途等）的入参出参以**专门的接口文档**为准，本工程的 `Networking/` 仅作可运行示例。

---

## 五、备注

- 交付产品是 SDK；本 App 的业务接口、AK 管理、UI 等均为**集成方侧参考实现**，可按需替换。
- 业务接口（世界 / 旅途等）的入参出参以**专门的接口文档**为准。
- `Pods/` 与 `*.xcworkspace` 由 `pod install` 生成，不纳入版本管理。
- 本示例只引用公开 subspec，可作为对外集成的参考样例。
