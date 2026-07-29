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
