# OpenMinis capability migration manifest

LocalAgent is the only shipping application. OpenMinis is a source donor for
selected product capabilities; its application target, agent loop, model
clients, stores, and platform bootstrap are not imported.

This manifest records file-level provenance without coupling LocalAgent to an
upstream repository revision. Copied and adapted OpenMinis source remains
covered by GPLv3. Package and bundled-asset licenses remain those of the
respective third parties.

## Core chat UI

| OpenMinis source | LocalAgent target | Xcode target/resource/build phase | License | Migration |
| --- | --- | --- | --- | --- |
| `src/ios/Views/Chat/AIChatView.swift`, `ChatInputBar.swift`, `ChatMessageViews.swift` | `LocalAgentApp/ThirdParty/OpenMinis/Product/OpenMinisProductShellView.swift` | `LocalAgentApp` Sources | GPLv3 | Product layout and interaction patterns adapted to the LocalAgent shell and injected facade |
| `src/ios/Agent/Markdown/MinisMarkdownParser.swift` | `LocalAgentApp/ThirdParty/OpenMinis/ChatUI/Markdown/MinisMarkdownParser.swift` | `LocalAgentApp` Sources | GPLv3; swift-cmark BSD-2-Clause | Copied; parser remains the product Markdown AST |
| `src/ios/Agent/Markdown/SwiftMathRenderer.swift` | `LocalAgentApp/ThirdParty/OpenMinis/ChatUI/Markdown/SwiftMathRenderer.swift` | `LocalAgentApp` Sources | GPLv3; SwiftMath MIT | Copied and adapted to LocalAgent logging and Swift 6 actor isolation |
| `src/ios/Agent/Markdown/KaTeXRenderer.swift` | `LocalAgentApp/ThirdParty/OpenMinis/ChatUI/Markdown/KaTeXRenderer.swift` | `LocalAgentApp` Sources | GPLv3; KaTeX MIT | Copied and adapted to LocalAgent logging and Swift 6 actor isolation |
| `src/ios/Resources/KaTeX` | `LocalAgentApp/ThirdParty/OpenMinis/Resources/KaTeX` | `LocalAgentApp` Copy Bundle Resources | KaTeX MIT | Copied as a folder resource |
| OpenMinis chat ViewModel/store surface | `LocalAgentApp/ThirdParty/OpenMinis/ChatUI/AIChatViewModel.swift`, `ChatStore.swift` | `LocalAgentApp` Sources | LocalAgent implementation; interface adapted from GPLv3 donor | Replaced with a presentation-only submit facade and read-only projection store |
| OpenMinis Markdown presentation behavior | `LocalAgentApp/ThirdParty/OpenMinis/ChatUI/Markdown/OpenMinisMarkdownView.swift` | `LocalAgentApp` Sources | LocalAgent implementation; behavior adapted from GPLv3 donor | Renders the migrated AST and invokes both migrated math backends |

The donor's `Agent/MessageList` implementation is intentionally not copied in
this slice: the current product path uses `LazyVStack`, and importing the
UIKit/TextKit message-list subsystem before it has a caller would add several
thousand lines of unreachable code. It remains available as a later,
performance-driven migration if profiling demonstrates a need.

## License records

| Source | LocalAgent target | Purpose |
| --- | --- | --- |
| `OpenMinis/LICENSE` | `LocalAgentApp/ThirdParty/OpenMinis/Licenses/GPL-3.0.txt` | GPLv3 source and distribution terms; `LocalAgentApp` Copy Bundle Resources |
| `OpenMinis/THIRD_PARTY_LICENSES.md` | `LocalAgentApp/ThirdParty/OpenMinis/Licenses/THIRD_PARTY_LICENSES.md` | Donor dependency and asset notices; `LocalAgentApp` Copy Bundle Resources |

The Swift package lock is stored in
`LocalAgentApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
Only `swift-cmark` and `SwiftMath` are introduced by the core chat slice.

## Native Linux and media inputs

Generated native artifacts are deliberately excluded from source control.
`scripts/prepare-ios-native.sh` rebuilds them from the pinned inputs in
`ThirdParty/OpenMinisNative/native-sources.lock`; the LocalAgent Xcode target
only verifies and consumes those outputs.

| OpenMinis source | LocalAgent target | Xcode target/resource/build phase | License | Migration |
| --- | --- | --- | --- | --- |
| `ish-arm64` build-reachable source closure | `ThirdParty/OpenMinisNative/iSH` | Built by `scripts/native/build_ish.sh`; generated headers/libraries are selected by `$(PLATFORM_NAME)` | iSH GPL/LGPL notices copied under `ThirdParty/OpenMinisNative/Licenses` | Kernel/emu/fs, ARM64 VDSO, fakefs tools, and RootfsPatch retained; donor App/CI/docs/benchmarks, inactive offload tests, `libapps`, and the unused vendored `libarchive` copy excluded |
| `scripts/build_lame.sh` | `scripts/native/build_lame.sh` | Produces platform-specific static library input | LGPL-2.0-or-later | Adapted to the LocalAgent lock file and output directory |
| `scripts/build_ffmpeg.sh`, `ffmpeg-patch/` | `scripts/native/build_ffmpeg.sh`, `ThirdParty/OpenMinisNative/Patches/FFmpeg` | Produces platform-specific frameworks | LGPL-2.1-or-later plus migrated patch source under GPLv3 | Adapted to verified downloads and LocalAgent paths |
| `scripts/prepare_alpine_rootfs.sh`, iSH `RootfsPatch.bundle` | `scripts/native/prepare_alpine_rootfs.sh`, generated `.build/resources` | `alpine-rootfs.zip` and `RootfsPatch.bundle` in `LocalAgentApp` Copy Bundle Resources | Alpine packages retain their own licenses; overlay source follows iSH | Rootfs version, URL, and digest are fixed; public DNS is not baked into the image |

## iSH, filesystem, browser, MCP, and tools

| OpenMinis source | LocalAgent target | Xcode target/resource/build phase | License | Migration |
| --- | --- | --- | --- | --- |
| `src/ios/iSH/ISHKernel.*`, `src/ios/Agent/ISH/ISHShellExecutor.*`, `CurrentRoot.*` | `LocalAgentApp/ThirdParty/OpenMinis/ISH/Runtime` | `LocalAgentApp` Sources through `LocalAgentApp-Bridging-Header.h` | GPLv3/iSH notices | Copied and reduced to the kernel/shell surface used by the product executor; product paths and identifiers use LocalAgent |
| `src/ios/Agent/ISH/RootfsManager.swift` | `LocalAgentApp/ThirdParty/OpenMinis/ISH/Rootfs/RootfsManager.swift` | `LocalAgentApp` Sources | GPLv3/iSH notices | Copied and adapted to the reproducible bundle inputs from the native build contract |
| `src/ios/default_mount` | `LocalAgentApp/ThirdParty/OpenMinis/Resources/default_mount` | `LocalAgentApp` Copy Bundle Resources | GPLv3 plus component notices | Copied and product-renamed; includes the `localagent-mcp-cli` client and daemon |
| `AIChatViewModel+ConcurrentTools.swift`, `AIChatViewModel+ToolPreflight.swift`, `ToolLoopDetector.swift` | `LocalAgentApp/ThirdParty/OpenMinis/Tools/OpenMinisToolBatchExecutor.swift`, `OpenMinisToolArgumentRepair.swift`, `ToolLoopDetector*.swift` | `LocalAgentApp` Sources | GPLv3 | Extracted from UI state into one ordered, cancellable batch executor with at most ten calls in flight and one detector per run |
| `AIChatViewModel+FileTools.swift`, `AIChatViewModel+ISHCommand.swift` | `LocalAgentApp/ThirdParty/OpenMinis/ISH/ToolFileResolver.swift`, `OpenMinisISHRuntime.swift`, `Tools/OpenMinisProductToolDispatcher.swift` | `LocalAgentApp` Sources | GPLv3 | Preserves ordinary guest paths and maps only the four declared `/var/localagent` host mounts; host paths never cross the tool contract |
| `src/ios/Agent/BrowserUse`, browser settings views | `LocalAgentApp/ThirdParty/OpenMinis/Tools/Browser` | `LocalAgentApp` Sources | GPLv3 | Copied and adapted for Swift 6, run-scoped ownership, `localagent://` URLs, LocalAgent shared mounts, and transcript-free download notifications |
| `src/ios/NativeOffloads` | Existing `LocalNativeToolkit` plus `OpenMinisProductToolDispatcher` adapter | Existing Swift package and `LocalAgentApp` Sources | LocalAgent source; donor offloads not copied | Reuses the existing permission-aware native catalog and durable effect ledger instead of shipping a duplicate calendar/photos/reminders implementation |

The MCP execution client is available inside the Linux guest and is reached
through the ordinary shell tool. Its management/rootfs UI is a later product
slice and does not block the Rust transcript/ReAct path. Credentials are not
added to the guest environment; model-provider API keys and OAuth tokens
remain in Swift secure storage.

The broad donor `NativeOffloads` directory and its device-specific UI are not
copied wholesale. Individual capabilities that the existing
`LocalNativeToolkit` does not cover (for example FFmpeg command offload) remain
eligible, caller-driven migration slices after the core Agent path is working.

## Skills and prompt documents

| OpenMinis source | LocalAgent target | Xcode target/resource/build phase | License | Migration |
| --- | --- | --- | --- | --- |
| `src/ios/Agent/Session/SkillStore.swift` and Skill import helpers | `LocalAgentApp/ThirdParty/OpenMinis/Skills/SkillStore.swift` | `LocalAgentApp` Sources; `/var/localagent/skills` host mount | GPLv3 | Import, archive validation, metadata parsing, editing, ordering, enablement, bundled installation, and conversation overrides adapted into one file-backed product store; eligible global changes expose a sync hook, while conversation overrides remain local |
| `src/ios/Views/Skills/SkillsManagementView.swift` | `LocalAgentApp/ThirdParty/OpenMinis/Skills/SkillsManagementView.swift` | `LocalAgentApp` Sources | GPLv3 | File/directory/URL/`.skill`/`.zip` management UI adapted to the LocalAgent store; the same file also contains the conversation-scoped Skills sheet reached from the chat header |
| OpenMinis prompt-building product UI | `LocalAgentApp/ThirdParty/OpenMinis/Skills/PromptDocumentStore.swift`, `PromptDocumentsSettingsView.swift` | `LocalAgentApp` Sources | LocalAgent implementation informed by GPLv3 donor UX | One ordered Markdown document store and native document-picker UI; no prompt graph or template engine |
| OpenMinis Skill/tool metadata assembly behavior | `LocalAgentApp/Runtime/RustAgentInputSnapshotProvider.swift`, `toolkit/Sources/LocalAgentBridge/TranscriptDTOs.swift` | `LocalAgentApp` Sources and `LocalAgentBridge` Swift package target | LocalAgent implementation | Freezes prompt documents, at most twenty Skill descriptors, and the single Swift tool catalog behind canonical digest domain `run-start-snapshot:v1`; Skill bodies, host paths, credentials, providers, Memory, and per-round Context are excluded |

Skills use Claude-style progressive disclosure. Rust initially receives only
ordered descriptor metadata with a stable virtual location such as
`/var/localagent/skills/example/SKILL.md`. The normal `file_read` tool resolves
that path through the read-only Skills mount only after the Agent chooses the
Skill. Sibling `scripts/`, `references/`, and `assets/` remain ordinary files
and are never recursively preloaded.

Rust validates and freezes this snapshot, then rebuilds the complete Context
from the canonical conversation on every model turn. Its `memory` module now
contains only contribution data and an injectable `MemoryProvider` contract
with `recall` and `remember_completed_turn`; no SQLite, HTTP, vector, graph, or
other production memory backend ships in this slice.

## Providers, OAuth, and model selection

| OpenMinis source | LocalAgent target | Xcode target/resource/build phase | License | Migration |
| --- | --- | --- | --- | --- |
| `src/ios/Providers/ProviderTypes.swift`, `ProviderInstance.swift` | `LocalAgentApp/ThirdParty/OpenMinis/Providers/OpenMinisProviderConfigurationAdapter.swift`, `LocalAgentLLMCloud/ProviderProductMapping.swift` | `LocalAgentApp` Sources and `LocalAgentLLMCloud` Swift package target | Product model adapted from GPLv3 donor; LocalAgent transport implementation | Preserves provider type, credential mode, label, Base URL and `/v1` behavior; unknown types round-trip and fail before network |
| `src/ios/Views/Providers/UnifiedModelPicker.swift` | `LocalAgentApp/ThirdParty/OpenMinis/Providers/UnifiedModelPicker.swift`, existing `ModelCenterView` | `LocalAgentApp` Sources | Product interaction adapted from GPLv3 donor | One picker projects both validated cloud models and installed compatible C++ local models; selection publishes a reusable target and does not start generation |
| Provider OAuth manager HTTP semantics | `LocalAgentLLMCloud/OAuthHTTPClient.swift`, existing `ProviderCredentialStore` | `LocalAgentLLMCloud` Swift package target | LocalAgent implementation informed by GPLv3 donor flows | OAuth endpoint profiles use the same exact-origin/SSRF transport boundary as model traffic; tokens stay in the existing secure credential vault and cancellation never triggers fallback |
| OpenAI-compatible provider product records | `ProviderPreset.swift`, `OpenAICompatibleAdapter.swift` | `LocalAgentLLMCloud` Swift package target | LocalAgent implementation | OpenAI Chat Completions, OpenRouter and Kimi share one codec implementation; Antigravity remains visible-but-disabled until its distinct Cloud Code envelope has a dedicated codec |

The donor generation clients and `LLMProviderFactory` are not present in the
shipping App. Provider discovery, validation, quick probes and generation keep
using the single `LocalAgentLLMCloud` HTTP stack. The migrated Provider
directory contains no direct `URLSession` calls. Existing API-key and Base URL
editing now also records whether the vault entry is an API key or OAuth token;
the secret itself is never part of the Codable product configuration, Rust
snapshot, host command, iSH environment, or ChatStore.

The donor `models-dev-api.json` is not copied: LocalAgent already has a signed,
production-trusted capability catalog. OpenRouter, Kimi and generic OpenAI Chat
models enter conservatively through manual discovery/validation until a future
signed catalog revision adds authoritative model rows.

## Rust canonical transcript and Swift projection

This slice uses existing LocalAgent code rather than donor source. Conversation
history belongs to Rust storage; `memory` is reserved for the later long-term
fact backend interface.

| Source | LocalAgent target | Build target | License | Migration |
| --- | --- | --- | --- | --- |
| Existing Rust conversation event stores under `rust-core/src/memory` | `rust-core/src/storage/*conversation*` | `local_ios_agent_runtime` | LocalAgent source | Renamed and reduced to conversation/session events, command receipts, replay and atomic append transactions; concrete long-term-memory tables were removed |
| Existing reliable Rust/Swift bridge envelopes | `rust-core/src/conversation`, `ffi_bridge.rs`, `LocalAgentBridge/TranscriptDTOs.swift` | Rust runtime and `LocalAgentBridge` | LocalAgent source | Added idempotent transcript commands, one active run per conversation, cancellable per-conversation projection replay and the existing canonical-digest registry; no second transport protocol or projection database |
| LocalAgent Rust execution core | `rust-core/src/agent_loop`, `rust-core/src/tool/batch.rs` | `local_ios_agent_runtime` | LocalAgent source | Replaced Agent business-state orchestration with one direct ReAct loop, fixed 200-model-turn guard, ordered Swift tool batches, atomic completed-round commits, run-scoped cancellation and conservative process-loss recovery |

Only Rust writes the canonical transcript. Swift receives ordered projections
identified by `(conversation_stream_id, sequence)` and can replay from its last
cursor after launch or a sequence gap. Presentation streaming remains
ephemeral and does not commit partial assistant or tool turns.

`rust-core/src/memory` is not conversation or session storage. It is only the
optional long-term-fact contribution/provider boundary; this slice ships no
concrete Memory backend.
