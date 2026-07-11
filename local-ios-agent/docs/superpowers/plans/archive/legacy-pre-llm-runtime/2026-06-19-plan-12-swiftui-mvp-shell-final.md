# Plan 12：SwiftUI MVP Shell 与 Rust Bridge 集成

**日期：** 2026-06-19  
**状态：** Final MVP Plan  
**前置条件：** Plan 1–11 当前实现可编译；本计划不进行 Rust 核心架构重构。  
**目标：** 构建一个真正可在 Xcode iOS Simulator 启动的 SwiftUI App，跑通 SwiftUI → Swift SDK → C ABI → Rust Runtime → Mock Provider → Runtime Events → SwiftUI 的完整链路，并验证一个无副作用工具回环。

---

## 1. 本计划解决什么

Plan 12 只解决“App 骨架是否真正跑起来”：

```text
SwiftUI ChatView
  → AgentViewModel
  → AgentRuntimeService
  → RustRuntimeClient
  → CLocalAgentRuntime C ABI
  → Rust AgentRuntime
  → MockStreamingProvider
  → AgentTurnResult / RuntimeEvent
  → Swift reducer
  → SwiftUI
```

同时验证一次最小工具回环：

```text
Rust 产生 debug.echo 工具请求
  → Swift 执行无副作用 echo
  → Swift 提交 ToolResult
  → Rust 继续模型调用
  → SwiftUI 显示最终结果
```

---

## 2. 明确不做什么

Plan 12 不包含：

- 真实模型调用；
- iPhone 端 C++ / Metal / llama.cpp 推理；
- Calendar、Reminders、Files、Photos 等真实系统 API；
- App Intents、Siri 或 Shortcuts；
- JavaScript/WASM Sandbox；
- 真正实时的 FFI token stream；
- 多 session UI、分支树 UI；
- 完整 Prompt Debug 页面；
- 完整 Audit 页面；
- 通用多工具并发与调度器；
- Rust `RunMachine/Effect/Driver` 架构重构；
- 对现有公开 C ABI 的破坏性修改。

允许做的 Rust 修改仅限 MVP 阻塞修复，例如：

- Simulator 链接和 feature gate；
- cancellation 错误映射；
- JSON contract 明显不一致；
- App 启动所需的最小桥接修复。

---

## 3. 当前代码基础

现有 Swift Package 已提供：

```text
LocalAgentBridge
LocalNativeToolkit
CLocalAgentRuntime（内部实现目标）
```

现有 Rust Bridge 已提供：

```text
create runtime
create session
send message
register tool
pending tool requests
submit tool result
approval APIs
cancel
provider APIs
```

现有缺口：

- 没有真正的 iOS Application target；
- Rust 产物仍通过本地 debug 搜索路径链接；
- 没有 App composition root；
- 没有最小 MVVM；
- 没有 App 内真实调用 `RustRuntimeClient` 的测试；
- 没有 Xcode Simulator 验收链路。

---

## 4. MVP 架构

```text
LocalAgentApp
├── AppBootstrapper
├── AppContainer
├── AgentViewModel              @MainActor
├── AgentRuntimeService         actor
├── RuntimeEventReducer         pure reducer
├── MinimalHostToolDriver
└── ChatView

AgentRuntimeService
├── RuntimeClient
├── ProviderControllingRuntimeClient
├── NativeToolExecutor
└── activeRun guard
```

### 4.1 职责边界

`ChatView`

- 只渲染状态；
- 只调用 ViewModel action；
- 不直接调用 RuntimeClient；
- 不解析 Rust JSON。

`AgentViewModel`

- 保存页面展示状态；
- 处理发送、取消、重试等用户意图；
- 调用 `AgentRuntimeService`；
- 不保存权威 run/session 状态。

`AgentRuntimeService`

- 唯一持有 `RuntimeClient` 的 App 服务；
- 创建 session；
- 发送消息；
- 应用 runtime events；
- 驱动一次最小工具回环；
- 防止同时发送两个 run。

`RuntimeEventReducer`

- 输入 `RuntimeEventDTO`；
- 输出新的 `AgentViewState`；
- 无网络、无 FFI、无 EventKit；
- 可单独单元测试。

`MinimalHostToolDriver`

- 仅支持 `debug.echo`；
- 一次只执行一个 request；
- 通过 `toolCallId` 做本次运行内的重复保护；
- continuation 上限为 4；
- 不承担完整 agent 状态机职责。

---

## 5. 建议文件结构

```text
local-ios-agent/
├── apps/
│   └── LocalAgentApp/
│       ├── LocalAgentApp.xcodeproj/
│       ├── LocalAgentApp/
│       │   ├── App/
│       │   │   └── LocalAgentApp.swift
│       │   ├── Composition/
│       │   │   ├── AppBootstrapper.swift
│       │   │   └── AppContainer.swift
│       │   ├── Runtime/
│       │   │   └── AgentRuntimeService.swift
│       │   ├── Tools/
│       │   │   └── MinimalHostToolDriver.swift
│       │   ├── State/
│       │   │   ├── AgentViewState.swift
│       │   │   └── RuntimeEventReducer.swift
│       │   ├── Presentation/
│       │   │   └── Chat/
│       │   │       ├── AgentViewModel.swift
│       │   │       └── ChatView.swift
│       │   └── Resources/
│       │       ├── Assets.xcassets
│       │       └── Info.plist
│       ├── LocalAgentAppTests/
│       │   ├── State/
│       │   │   └── RuntimeEventReducerTests.swift
│       │   ├── Runtime/
│       │   │   └── AgentRuntimeServiceTests.swift
│       │   ├── Tools/
│       │   │   └── MinimalHostToolDriverTests.swift
│       │   ├── Presentation/
│       │   │   └── Chat/
│       │   │       └── AgentViewModelTests.swift
│       │   └── Integration/
│       │       └── RustRuntimeAppIntegrationTests.swift
│
├── scripts/
│   ├── build-rust-ios-simulator.sh
│   └── package-rust-runtime-xcframework.sh
│
└── toolkit/
    ├── Package.swift
    └── Sources/
        ├── LocalAgentBridge/
        └── LocalNativeToolkit/
```

---

## 6. Task 0：冻结 v1 协议并解决 Simulator 链接

### 6.1 冻结公开边界

在完成 MVP 前保持以下内容兼容：

- 现有 C 函数名；
- `RuntimeClient` 方法；
- JSON 字段名；
- enum 字符串；
- Rust 返回字符串的释放方式。

新增 golden contract tests：

- Rust FFI 产生的 `AgentTurnResult` 可被 Swift DTO 解码；
- Rust FFI error envelope 可被 Swift 解码；
- 所有当前 `RuntimeEventKindDTO` 与 Rust 映射一致。

### 6.2 生成 Simulator 可链接产物

首选方案：

```text
LocalAgentRuntime.xcframework
  └── ios-arm64-simulator slice
```

步骤：

- [ ] 安装 `aarch64-apple-ios-sim` Rust target；
- [ ] 使用 Xcode SDK/clang 工具链构建；
- [ ] 打包静态库和 C header；
- [ ] 通过本地 SwiftPM `binaryTarget(path:)` 或稳定 Xcode 链接方式接入；
- [ ] 删除 App 对 `rust-core/target/debug` 的直接依赖；
- [ ] 不让 App 再添加第二条临时 Rust 搜索路径。

如果 on-device inference 的未解析 C 符号阻塞 Simulator 链接：

- [ ] 将 on-device C ABI adapter 放在明确 feature 后；
- [ ] Plan 12 的 Simulator 构建不启用 on-device feature；
- [ ] 保留 Mock 和 Desktop provider。

### 6.3 Task 0 验收

空白 Simulator App 可以：

1. 加载 `LocalAgentBridge`；
2. 创建 `RustRuntimeClient`；
3. 创建和释放 Rust runtime；
4. 无 duplicate symbol、wrong architecture、undefined symbol。

---

## 7. Task 1：创建真实 Xcode App Target

- [ ] 创建 `apps/LocalAgentApp/LocalAgentApp.xcodeproj`；
- [ ] iOS deployment target 设为 iOS 17 或项目统一版本；
- [ ] Swift 6；
- [ ] 创建 App、Unit Test、UI Test targets；
- [ ] 创建 shared scheme；
- [ ] 添加本地 `../../toolkit` Swift Package；
- [ ] App 只链接：
  - `LocalAgentBridge`
  - `LocalNativeToolkit`
- [ ] App 源码禁止 `import CLocalAgentRuntime`；
- [ ] 空白 App 可在 Simulator 启动。

---

## 8. Task 2：建立 Composition Root

实现：

```swift
struct AppContainer {
    let runtimeService: AgentRuntimeService
}
```

`AppBootstrapper` 负责：

1. 创建 runtime configuration；
2. 创建 `RustRuntimeClient`；
3. 创建 NativeToolCatalog；
4. 注册 `debug.echo` schema；
5. 创建 `MinimalHostToolDriver`；
6. 创建 `AgentRuntimeService`；
7. 将服务注入 ViewModel。

Plan 12 默认配置：

```text
provider = mock
store = in_memory（自动化测试）
store = sqlite（App 手工持久化验收）
```

禁止：

- View 自己创建 runtime；
- 多处分别创建 Rust handle；
- ViewModel 直接持有 C function table；
- NativeTool 直接回调 RuntimeClient。

---

## 9. Task 3：实现最小 MVVM 状态

建议状态：

```swift
enum AppRuntimePhase {
    case booting
    case ready
    case running(runId: String)
    case failed(message: String)
}

struct AgentMessageViewState {
    let id: String
    let role: Role
    var text: String
    var isStreaming: Bool
}

struct AgentViewState {
    var phase: AppRuntimePhase
    var messages: [AgentMessageViewState]
    var draft: String
    var currentSessionId: String?
    var errorMessage: String?
}
```

最小 reducer 只支持：

```text
sessionCreated
userMessage
assistantMessageStarted
assistantTextDelta
assistantMessageCompleted
toolCallRequested
toolResultMessage
runCancelled
runFailed
```

未知但可忽略的展示事件：

- 保留日志；
- 不让 App 崩溃；
- 不在本阶段构建完整 UI。

---

## 10. Task 4：跑通 Mock Chat

发送流程：

```text
用户点击 Send
  → ViewModel 校验输入
  → RuntimeService 创建/复用 session
  → RuntimeClient.sendMessage
  → 返回 AgentTurnResultDTO
  → reducer 顺序应用 events
  → View 刷新
```

要求：

- [ ] 空输入不发送；
- [ ] 一个 run 活跃时禁止第二次发送；
- [ ] 用户消息只以 Rust event 为权威记录；
- [ ] assistant delta 按 event 顺序合并；
- [ ] completed 后关闭 streaming 状态；
- [ ] failure 显示用户可见错误；
- [ ] App 不在主线程直接执行阻塞 FFI。

验收：

```text
输入：hello
输出：Mock response to: hello
```

---

## 11. Task 5：跑通一个最小工具回环

注册：

```text
debug.echo
risk = read_only
input = {"text": string}
```

执行流程：

```text
Mock provider 请求 debug.echo
  → Rust 返回 waiting_tool
  → Swift 读取当前 run 的 pending request
  → MinimalHostToolDriver 执行
  → Swift 提交 ToolResult
  → Rust 再次调用 Mock provider
  → 最终 completed
```

重复保护：

- [ ] 使用 `toolCallId` 作为本次 App 生命周期内的执行键；
- [ ] 已完成 call 不再次执行；
- [ ] continuation 最大 4 次；
- [ ] 超过上限后以用户可见错误终止；
- [ ] 不实现自动 retry。

验收：

- request 只执行一次；
- pending request 被消费；
- 最终模型 continuation 可见；
- 没有真实系统副作用。

---

## 12. Task 6：最小 SQLite 持久化验收

App 的 SQLite 路径放在应用 sandbox 的 Application Support 目录，例如：

```text
<Application Support>/LocalAgent/agent.sqlite
```

要求：

- [ ] 目录不存在时创建；
- [ ] App 配置中不硬编码开发机绝对路径；
- [ ] 创建 session 并发送消息；
- [ ] 退出并重新启动 App；
- [ ] Rust 能列出此前 session；
- [ ] 不要求在 Plan 12 实现完整历史列表 UI；
- [ ] 单元测试继续使用临时文件或 in-memory store。

此任务只验证存储链路，不引入长期记忆。

---

## 13. Task 7：错误和取消

必须覆盖：

- runtime 初始化失败；
- FFI 返回空指针/错误 envelope；
- send message 失败；
- provider error；
- 用户取消；
- 重复发送被拒绝。

MVP 阻塞修复：

- provider 返回 `AgentError::Cancelled` 时，run 最终必须表现为 `RunCancelled`；
- 不得将用户主动取消展示为普通 provider failure；
- cancel 不应要求 Swift 直接访问 cancellation registry。

Plan 12 不承诺真正逐 token 实时取消。它只要求：

- App 可以触发取消；
- runtime 状态一致；
- UI 不永久卡在 running。

---

## 14. Task 8：Plan 12 测试

### Rust

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml
```

重点：

- Mock chat；
- tool continuation；
- cancellation；
- SQLite replay；
- FFI JSON contract。

### Swift Package

```bash
swift test --package-path local-ios-agent/toolkit
```

重点：

- DTO；
- RustRuntimeClient contract；
- NativeToolExecutor；
- debug.echo。

### Xcode App

```bash
xcodebuild \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  test
```

### Simulator 手工验收

- [ ] App 冷启动；
- [ ] mock 聊天；
- [ ] debug.echo；
- [ ] cancel；
- [ ] SQLite 重启恢复；
- [ ] 无主线程明显冻结；
- [ ] Xcode console 无 FFI 内存释放错误。

---

## 15. Definition of Done

Plan 12 完成必须同时满足：

1. 真正的 Xcode iOS App 可在 Simulator 启动；
2. App 使用 `RustRuntimeClient`，不是 Swift-only mock；
3. 一条消息经过真实 C ABI 到达 Rust；
4. Runtime events 被 SwiftUI 正确投影；
5. `debug.echo` 完成一次工具续跑；
6. App 可以显示错误和取消状态；
7. SQLite 路径在 App sandbox 内并通过重启验证；
8. Rust、Swift Package、App Unit、XCUITest 全部通过；
9. 未开始大规模 Rust 重构。

---

## 16. 下一步

```text
Plan 13：Simulator 接入 Mac 本地真实模型
Plan 14：接入基本 iOS System Tools
MVP Acceptance：全链条测试与真实表现报告
完成以上门槛后，再启动后续重构
```
