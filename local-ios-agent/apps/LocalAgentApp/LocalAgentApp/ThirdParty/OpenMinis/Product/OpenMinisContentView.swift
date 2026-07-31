import SwiftUI
import UIKit

// Direct product-layer port of OpenMinis ContentView. Its split/stack
// navigation, sidebar toolbar, movable new-chat/search controls and Settings
// sheet stay in the donor shape. LocalAgent replaces only the data/runtime
// edges with its Rust-backed projections and existing product destinations.
@MainActor
struct OpenMinisContentView: View {
    private static let compactThreshold: CGFloat = 700

    @Bindable var shellViewModel: AppShellViewModel
    @ObservedObject var chatViewModel: AIChatViewModel
    @ObservedObject var chatStore: ChatStore
    @Bindable var builderViewModel: AgentBuilderViewModel
    @Bindable var toolCenterViewModel: ToolCenterViewModel
    @Bindable var modelCenterViewModel: ModelCenterViewModel
    let debugService: RunDebugService?
    var onUsePublishedAgent: (PublishedAgentSelection) -> Void

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var navigationPath: [String] = []
    @State private var selectedSessionID: String?
    @State private var currentStackSessionID: String?
    @State private var activeToolSheet: OpenMinisToolSheet?
    @State private var activeDebugRunID: String?
    @State private var isWideLayout = false
    @StateObject private var browserPool = BrowserTabPool()

    @AppStorage("openminis.fab-on-left") private var fabOnLeft = false
    @AppStorage("localagent.appearance") private var appearance = "system"
    @State private var fabDragOffset: CGFloat = 0
    @State private var fabDidDrag = false
    @State private var searchDragOffset: CGFloat = 0
    @State private var searchDidDrag = false
    @State private var showSearchBar = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    private var isIPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = isIPad && geometry.size.width >= Self.compactThreshold
            Group {
                if wide {
                    splitLayout
                } else {
                    stackLayout
                }
            }
            .onAppear {
                isWideLayout = wide
                present(shellViewModel.route)
            }
            .onChange(of: wide) { _, isWide in
                isWideLayout = isWide
                present(shellViewModel.route)
            }
        }
        .onChange(of: shellViewModel.route) { _, route in
            present(route)
        }
        .onChange(of: shellViewModel.showsConversationList) { _, shouldShow in
            guard shouldShow else { return }
            showConversationList()
            shellViewModel.showsConversationList = false
        }
        .preferredColorScheme(preferredColorScheme)
        .sheet(item: $activeToolSheet, onDismiss: restoreChatRoute) { sheet in
            switch sheet {
            case .settings:
                OpenMinisSettingsSheet(
                    shellViewModel: shellViewModel,
                    builderViewModel: builderViewModel,
                    toolCenterViewModel: toolCenterViewModel,
                    modelCenterViewModel: modelCenterViewModel,
                    browserPool: browserPool,
                    onUsePublishedAgent: onUsePublishedAgent
                )
            case .models:
                NavigationStack {
                    ModelCenterView(
                        viewModel: modelCenterViewModel,
                        activeAgent: shellViewModel.activeAgent,
                        onActiveModelChanged: {
                            shellViewModel.activeModel = $0
                        }
                    )
                }
            case .agents:
                AgentBuilderView(
                    viewModel: builderViewModel,
                    onUseInChat: onUsePublishedAgent
                )
            case .tools:
                NavigationStack {
                    ToolCenterView(viewModel: toolCenterViewModel)
                }
            case .browser:
                BrowserSheetView(pool: browserPool)
            case .browserManagement:
                NavigationStack {
                    BrowserManagementView(pool: browserPool)
                }
            case .debug:
                NavigationStack {
                    if let debugService {
                        DebugTraceView(
                            routeRunId: activeDebugRunID,
                            activeAgent: shellViewModel.activeAgent,
                            debugService: debugService
                        )
                    } else {
                        ContentUnavailableView(
                            "Debug Unavailable",
                            systemImage: "ladybug.slash",
                            description: Text(
                                "The Rust execution bridge is not available in this runtime."
                            )
                        )
                    }
                }
            }
        }
    }

    // MARK: - OpenMinis split / stack navigation

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sessionList(useNavigationLinks: false)
        } detail: {
            NavigationStack {
                if let selectedSessionID {
                    chat(sessionID: selectedSessionID)
                } else {
                    OpenMinisDetailPlaceholder()
                }
            }
        }
    }

    private var stackLayout: some View {
        NavigationStack(path: $navigationPath) {
            sessionList(useNavigationLinks: true)
                .navigationDestination(for: String.self) { sessionID in
                    chat(sessionID: sessionID)
                        .id(sessionID)
                        .onAppear { currentStackSessionID = sessionID }
                }
        }
    }

    @ViewBuilder
    private func chat(sessionID: String) -> some View {
        OpenMinisChatView(
            shellViewModel: shellViewModel,
            viewModel: chatViewModel,
            chatStore: chatStore,
            onOpenBuilder: { activeToolSheet = .agents },
            onOpenModels: { activeToolSheet = .models },
            onOpenConversation: openConversation,
            onShowConversations: showConversationList
        )
        .id(sessionID)
    }

    @ViewBuilder
    private func sessionList(useNavigationLinks: Bool) -> some View {
        List {
            if !shellViewModel.readinessBanners.isEmpty {
                Section {
                    ForEach(shellViewModel.readinessBanners) { banner in
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(banner.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(banner.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                    }
                }
            }

            ForEach(
                Array(groupedSessions.enumerated()),
                id: \.offset
            ) { _, group in
                Section(group.label) {
                    ForEach(group.sessions) { session in
                        OpenMinisSessionRow(
                            session: session,
                            isActive: chatStore.activeRunID(
                                conversationStreamID: session.sessionId
                            ) != nil,
                            highlightQuery: searchText
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            openConversation(session.sessionId)
                        }
                        .background {
                            if useNavigationLinks {
                                NavigationLink(value: session.sessionId) {
                                    EmptyView()
                                }
                                .opacity(0)
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if filteredSessions.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No Conversations" : "No Results",
                    systemImage: searchText.isEmpty
                        ? "bubble.left.and.bubble.right"
                        : "magnifyingglass",
                    description: Text(
                        searchText.isEmpty
                            ? "Start a new conversation with your Agent."
                            : "Try a different search term."
                    )
                )
            }
        }
        .safeAreaInset(edge: .bottom) { fabRow }
        .ignoresSafeArea(.keyboard, edges: showSearchBar ? [] : .bottom)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { sidebarToolbarContent }
    }

    private var filteredSessions: [ChatSession] {
        let ordered = chatStore.sessions.sorted {
            ($0.lastMessageDate ?? .distantPast)
                > ($1.lastMessageDate ?? .distantPast)
        }
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else { return ordered }
        return ordered.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.searchText.localizedCaseInsensitiveContains(query)
        }
    }

    private var groupedSessions: [(label: String, sessions: [ChatSession])] {
        let calendar = Calendar.current
        let now = Date()
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        var today: [ChatSession] = []
        var yesterday: [ChatSession] = []
        var previousWeek: [ChatSession] = []
        var older: [ChatSession] = []

        for session in filteredSessions {
            guard let date = session.lastMessageDate else {
                older.append(session)
                continue
            }
            if calendar.isDateInToday(date) {
                today.append(session)
            } else if calendar.isDateInYesterday(date) {
                yesterday.append(session)
            } else if date >= weekAgo {
                previousWeek.append(session)
            } else {
                older.append(session)
            }
        }

        return [
            ("Today", today),
            ("Yesterday", yesterday),
            ("Previous 7 Days", previousWeek),
            ("Older", older),
        ].compactMap { label, sessions in
            sessions.isEmpty ? nil : (label, sessions)
        }
    }

    // MARK: - OpenMinis sidebar toolbar

    @ToolbarContentBuilder
    private var sidebarToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text(shellViewModel.activeAgent?.displayName ?? "Minis")
                .font(.system(size: 18.5, weight: .semibold))
        }

        ToolbarItem(placement: .topBarLeading) {
            Button {
                activeToolSheet = .settings
            } label: {
                Image(systemName: "gear")
            }
            .accessibilityLabel("Settings")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                activeToolSheet = .models
            } label: {
                Image(systemName: "cpu")
            }
            .accessibilityLabel("Choose local or cloud model")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    activeToolSheet = .tools
                } label: {
                    Label("Tools & Linux", systemImage: "terminal")
                }
                Button {
                    activeToolSheet = .agents
                } label: {
                    Label("Agent Builder", systemImage: "slider.horizontal.3")
                }
                Button {
                    activeToolSheet = .models
                } label: {
                    Label("Local & Cloud Models", systemImage: "cpu")
                }
                Divider()
                Button {
                    activeToolSheet = .browser
                } label: {
                    Label("Open Browser", systemImage: "globe")
                }
                Button {
                    activeToolSheet = .browserManagement
                } label: {
                    Label(
                        "Browser Settings",
                        systemImage: "globe.badge.chevron.backward"
                    )
                }
            } label: {
                Image(systemName: "terminal.circle")
                    .font(.system(size: 22))
            }
        }
    }

    // MARK: - OpenMinis movable new-chat / search controls

    private var fabRow: some View {
        ZStack {
            DraggableFAB(
                fabOnLeft: $fabOnLeft,
                dragOffset: $fabDragOffset,
                didDrag: $fabDidDrag
            ) {
                if !fabDidDrag { newConversation() }
            } label: {
                Circle()
                    .fill(Color(UIColor.secondarySystemBackground))
                    .overlay {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color(UIColor.label))
                    }
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            }

            if !chatStore.sessions.isEmpty {
                if showSearchBar {
                    GeometryReader { geometry in
                        let size: CGFloat = 56
                        let edgePadding: CGFloat = 16
                        let gap: CGFloat = 10
                        let x = fabOnLeft
                            ? edgePadding + size + gap
                            : edgePadding
                        let width = geometry.size.width
                            - edgePadding * 2
                            - size
                            - gap

                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Search chats...", text: $searchText)
                                .textFieldStyle(.plain)
                                .focused($searchFocused)
                            Button {
                                dismissSearch()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 18)
                        .frame(width: width, height: size)
                        .background(Color(UIColor.secondarySystemBackground))
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                        .position(x: x + width / 2, y: size / 2)
                    }
                    .onAppear { searchFocused = true }
                    .transition(
                        .scale(
                            scale: 0.85,
                            anchor: fabOnLeft ? .leading : .trailing
                        )
                        .combined(with: .opacity)
                    )
                } else {
                    DraggableFAB(
                        fabOnLeft: $fabOnLeft,
                        dragOffset: $searchDragOffset,
                        didDrag: $searchDidDrag,
                        inverted: true
                    ) {
                        if !searchDidDrag {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showSearchBar = true
                            }
                        }
                    } label: {
                        Circle()
                            .fill(Color(UIColor.secondarySystemBackground))
                            .overlay {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(Color(UIColor.label))
                            }
                            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    }
                }
            }
        }
        .frame(height: 56)
        .padding(.bottom, 20)
    }

    private func dismissSearch() {
        searchFocused = false
        searchText = ""
        withAnimation(.easeInOut(duration: 0.2)) {
            showSearchBar = false
        }
    }

    // MARK: - Routing adapters

    private func newConversation() {
        openConversation(
            "conversation-\(UUID().uuidString.lowercased())"
        )
    }

    private func openConversation(_ conversationStreamID: String) {
        shellViewModel.open(.chat(sessionId: conversationStreamID))
    }

    private func showConversationList() {
        if isWideLayout {
            selectedSessionID = nil
        } else {
            navigationPath.removeAll()
            currentStackSessionID = nil
        }
    }

    private func present(_ route: AppRoute) {
        switch route {
        case let .chat(sessionID):
            guard let sessionID else { return }
            activeToolSheet = nil
            if isWideLayout {
                selectedSessionID = sessionID
            } else if navigationPath.last != sessionID {
                navigationPath = [sessionID]
            }
        case .agents, .builder:
            activeToolSheet = .agents
        case .tools:
            activeToolSheet = .tools
        case .models:
            activeToolSheet = .models
        case .settings:
            activeToolSheet = .settings
        case let .debug(runID):
            activeDebugRunID = runID
            activeToolSheet = .debug
        }
    }

    private func restoreChatRoute() {
        guard case .chat = shellViewModel.route else {
            let sessionID = selectedSessionID
                ?? currentStackSessionID
                ?? chatViewModel.conversationStreamID
            shellViewModel.open(.chat(sessionId: sessionID))
            return
        }
    }
}

private enum OpenMinisToolSheet: String, Identifiable {
    case settings
    case models
    case agents
    case tools
    case browser
    case browserManagement
    case debug

    var id: String { rawValue }
}

// Copied from OpenMinis ContentView and kept intentionally local to the
// product root so navigation owns its drag state.
private struct DraggableFAB<Label: View>: View {
    @Binding var fabOnLeft: Bool
    @Binding var dragOffset: CGFloat
    @Binding var didDrag: Bool
    var inverted = false
    var onTap: () -> Void
    @ViewBuilder var label: () -> Label

    private let fabSize: CGFloat = 56
    private let edgePadding: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let screenWidth = geometry.size.width
            let leftX = edgePadding + fabSize / 2
            let rightX = screenWidth - edgePadding - fabSize / 2
            let onLeft = inverted ? !fabOnLeft : fabOnLeft
            let restingX = onLeft ? leftX : rightX

            label()
                .frame(width: fabSize, height: fabSize)
                .position(x: restingX + dragOffset, y: fabSize / 2)
                .onTapGesture(perform: onTap)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            didDrag = true
                            dragOffset = value.translation.width
                        }
                        .onEnded { value in
                            let center = restingX + value.translation.width
                            let droppedOnLeft = center < screenWidth / 2
                            let newFabOnLeft = inverted
                                ? !droppedOnLeft
                                : droppedOnLeft
                            let changed = fabOnLeft != newFabOnLeft
                            withAnimation(
                                .spring(
                                    response: 0.35,
                                    dampingFraction: 0.75
                                )
                            ) {
                                fabOnLeft = newFabOnLeft
                                dragOffset = 0
                            }
                            if changed {
                                UIImpactFeedbackGenerator(
                                    style: .medium
                                ).impactOccurred()
                            }
                            DispatchQueue.main.asyncAfter(
                                deadline: .now() + 0.15
                            ) {
                                didDrag = false
                            }
                        }
                )
        }
        .frame(height: fabSize)
    }
}

private struct OpenMinisSessionRow: View {
    let session: ChatSession
    let isActive: Bool
    let highlightQuery: String

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Image(systemName: "bubble.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                if isActive {
                    ProgressView()
                        .controlSize(.small)
                        .offset(x: 16, y: 16)
                }
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                highlightedText(
                    session.title,
                    font: .system(size: 16, weight: .semibold),
                    color: Color(UIColor.label)
                )
                .lineLimit(1)

                highlightedText(
                    session.searchText.isEmpty
                        ? "No messages yet"
                        : session.searchText,
                    font: .system(size: 14),
                    color: Color(UIColor.secondaryLabel)
                )
                .lineLimit(1)
            }

            Spacer(minLength: 1)

            if let date = session.lastMessageDate {
                Text(date, style: .relative)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(UIColor.tertiaryLabel))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func highlightedText(
        _ value: String,
        font: Font,
        color: Color
    ) -> some View {
        if !highlightQuery.isEmpty,
           value.localizedCaseInsensitiveContains(highlightQuery) {
            Text(value)
                .font(font)
                .foregroundStyle(Color.accentColor)
        } else {
            Text(value)
                .font(font)
                .foregroundStyle(color)
        }
    }
}

private struct OpenMinisDetailPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Conversation Selected")
                .font(.title3.bold())
            Text("Select a conversation or start a new one")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Directly follows OpenMinis SettingsSheet's section order with monochrome SF
// Symbols. LocalAgent-specific Rust, local-model and Agent Builder pages are
// inserted as destinations rather than replacing the donor navigation.
private struct OpenMinisSettingsSheet: View {
    @Bindable var shellViewModel: AppShellViewModel
    @Bindable var builderViewModel: AgentBuilderViewModel
    @Bindable var toolCenterViewModel: ToolCenterViewModel
    @Bindable var modelCenterViewModel: ModelCenterViewModel
    @ObservedObject var browserPool: BrowserTabPool
    var onUsePublishedAgent: (PublishedAgentSelection) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        OpenMinisProviderInstancesView(
                            viewModel: modelCenterViewModel
                        )
                    } label: {
                        OpenMinisSettingsLabel(
                            "Manage Providers & Models",
                            systemImage: "key"
                        )
                    }

                    NavigationLink {
                        ModelCenterView(
                            viewModel: modelCenterViewModel,
                            activeAgent: shellViewModel.activeAgent,
                            onActiveModelChanged: {
                                shellViewModel.activeModel = $0
                            }
                        )
                    } label: {
                        OpenMinisSettingsLabel(
                            "Local Models",
                            systemImage: "cpu"
                        )
                    }

                    NavigationLink {
                        AgentBuilderView(
                            viewModel: builderViewModel,
                            onUseInChat: onUsePublishedAgent
                        )
                    } label: {
                        OpenMinisSettingsLabel(
                            "Model Groups & Agent Bindings",
                            systemImage: "square.stack.3d.up"
                        )
                    }
                } header: {
                    Text("LLM Providers")
                } footer: {
                    Text(
                        "Configure API keys, OAuth and Base URLs, download on-device models, and order fallback candidates for the Rust Agent Core."
                    )
                }

                Section("Agent Runtime") {
                    NavigationLink {
                        AgentBuilderView(
                            viewModel: builderViewModel,
                            onUseInChat: onUsePublishedAgent
                        )
                    } label: {
                        OpenMinisSettingsLabel(
                            "Agent Builder",
                            systemImage: "slider.horizontal.3"
                        )
                    }

                    NavigationLink {
                        SkillsManagementView()
                    } label: {
                        OpenMinisSettingsLabel(
                            "Skills",
                            systemImage: "puzzlepiece.extension"
                        )
                    }

                    NavigationLink {
                        PromptDocumentsSettingsView()
                    } label: {
                        OpenMinisSettingsLabel(
                            "Prompt Documents",
                            systemImage: "doc.text"
                        )
                    }

                    NavigationLink {
                        ToolCenterView(viewModel: toolCenterViewModel)
                    } label: {
                        OpenMinisSettingsLabel(
                            "Tools & Linux",
                            systemImage: "terminal"
                        )
                    }

                    NavigationLink {
                        BrowserManagementView(pool: browserPool)
                    } label: {
                        OpenMinisSettingsLabel(
                            "Browser Settings",
                            systemImage: "globe"
                        )
                    }
                }

                Section("Privacy & Storage") {
                    NavigationLink {
                        PrivacySettingsView(
                            shellViewModel: shellViewModel,
                            toolCenterViewModel: toolCenterViewModel
                        )
                    } label: {
                        OpenMinisSettingsLabel(
                            "Privacy, Storage & Permissions",
                            systemImage: "lock.shield"
                        )
                    }
                }

                Section("Appearance") {
                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        OpenMinisSettingsLabel(
                            "Appearance",
                            systemImage: "paintbrush"
                        )
                    }
                }

                Section("About") {
                    NavigationLink {
                        AboutLocalAgentView()
                    } label: {
                        OpenMinisSettingsLabel(
                            "About LocalAgent",
                            systemImage: "info.circle"
                        )
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage("localagent.appearance") private var appearance = "system"

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    Text("System Default").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.inline)
            } footer: {
                Text("Use the system appearance or keep LocalAgent in a fixed color scheme.")
            }
        }
        .navigationTitle("Appearance")
    }
}

private struct AboutLocalAgentView: View {
    private let bundle = Bundle.main

    private var version: String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        List {
            Section("LocalAgent") {
                LabeledContent("Version", value: version)
                LabeledContent("Build", value: build)
            }

            Section("Runtime") {
                LabeledContent("Agent Runtime", value: "Rust ReAct Core")
            }
        }
        .navigationTitle("About LocalAgent")
    }
}

private struct OpenMinisSettingsLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    init(
        _ title: LocalizedStringKey,
        systemImage: String
    ) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)
        }
    }
}
