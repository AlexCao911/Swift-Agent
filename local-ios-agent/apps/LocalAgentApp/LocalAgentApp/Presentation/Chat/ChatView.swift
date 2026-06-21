import SwiftUI

struct ChatView: View {
    // 配合你最新的 @Observable 模型使用
    @Bindable var viewModel: AgentViewModel
    
    // 用于控制滚动
    @State private var scrollProxy: ScrollViewProxy?

    var body: some View {
        NavigationStack {
            ZStack {
                // 1. 背景色：使用系统标准背景
                Color(.systemBackground)
                    .ignoresSafeArea()

                // 2. 消息列表
                messageList
            }
            // 3. 底部输入栏：使用 safeAreaInset 是现代 iOS 的标准做法
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composerView
                    .background(.thinMaterial) // 使用毛玻璃效果作为输入栏背景
            }
            // 4. 原生导航栏配置
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 中间的主标题和副标题
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text("Local Agent")
                            .font(.headline)
                        Text(phaseText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // 右侧的停止按钮
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.state.phase.isRunning {
                        Button {
                            Task { await viewModel.cancel() }
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.red)
                                .font(.system(size: 22))
                        }
                    }
                }

                ToolbarItem(placement: .topBarLeading) {
                    providerMenu
                }
            }
        }
        .task {
             // 启动逻辑保持不变
             if case .booting = viewModel.state.phase {
                 await viewModel.bootstrap()
             }
         }
    }

    // MARK: - Message List View

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    // 顶部留白，让第一条消息不顶着导航栏
                    Color.clear.frame(height: 8)

                    ForEach(viewModel.state.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id) // 确保你的 AgentMessageViewState 有 id 属性
                    }

                    if let error = viewModel.state.errorMessage {
                        errorView(text: error)
                    }
                    
                    // 底部留白，防止最后一条消息被输入栏遮挡太紧
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { scrollProxy = proxy }
            // 监听消息数量变化以自动滚动到底部
            .onChange(of: viewModel.state.messages.count) {
                scrollToBottom()
            }
            // 监听键盘弹出导致的排版变化，确保最后一条消息可见
            .onChange(of: viewModel.state.draft) {
                scrollToBottom()
            }
        }
    }
    
    private func scrollToBottom() {
        guard let lastId = viewModel.state.messages.last?.id else { return }
        // 使用较短的动画让滚动更跟手
        withAnimation(.easeOut(duration: 0.25)) {
            scrollProxy?.scrollTo(lastId, anchor: .bottom)
        }
    }

    // 错误提示 View
    private func errorView(text: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text)
        }
        .font(.footnote)
        .foregroundStyle(.white)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.red.opacity(0.8), in: Capsule())
        .padding(.vertical, 8)
    }

    // MARK: - Composer View (Input Bar)

    private var composerView: some View {
        VStack(spacing: 0) {
            Divider() // 顶部一条细分割线
            
            HStack(alignment: .bottom, spacing: 12) {
                // 输入框：模仿 iMessage 的胶囊样式
                TextField("iMessage", text: $viewModel.state.draft, axis: .vertical)
                    .font(.body)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background {
                        Capsule()
                            .fill(Color(.systemGray6)) // 使用极浅的灰色填充
                    }
                    .overlay {
                        Capsule()
                            .stroke(Color(.separator).opacity(0.5), lineWidth: 0.5)
                    }
                    .lineLimit(1...6) // 限制最大高度
                    .disabled(viewModel.state.phase.isRunning)

                // 发送按钮
                Button {
                    Task { await viewModel.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isSendDisabled ? Color(.systemGray4) : .white, isSendDisabled ? Color(.systemGray5) : Color.accentColor)
                        .background(Color.white.opacity(0.01)) // 增加点击热区
                }
                .disabled(isSendDisabled)
                .animation(.easeInOut(duration: 0.2), value: isSendDisabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Helpers
    
    private var isSendDisabled: Bool {
        viewModel.state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.state.phase.isRunning
    }

    private var providerMenu: some View {
        Menu {
            ForEach(viewModel.state.provider.profiles, id: \.id) { profile in
                Button {
                    Task { await viewModel.selectProvider(profile.id) }
                } label: {
                    Label(
                        profile.displayName,
                        systemImage: profile.id == viewModel.state.provider.active?.id ? "checkmark" : "cpu"
                    )
                }
                .disabled(viewModel.state.phase.isRunning)
            }
        } label: {
            Image(systemName: "cpu")
        }
        .accessibilityLabel("Provider")
        .disabled(viewModel.state.provider.profiles.isEmpty)
    }

    private var phaseText: String {
        switch viewModel.state.phase {
        // 如果你的 phase 枚举名称有所不同，请在这里微调
        case .booting:    return "正在启动..."
        case .ready:      return "在线"
        case .running:    return "对方正在输入..."
        case .failed:     return "连接中断"
        }
    }
}

// MARK: - Message Bubble Subview

private struct MessageBubble: View {
    let message: AgentMessageViewState // 确保这里是你真实的 Model 类型
    @Environment(\.colorScheme) var colorScheme

    var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: .leading, spacing: 4) {
                Text(messageText)
                    .font(.body)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .foregroundStyle(foreground)
                    .background {
                        // 更大的圆角，模仿现代 iOS 风格
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(background)
                    }
            }
            // 控制最大宽度
            .frame(maxWidth: UIScreen.main.bounds.width * 0.75, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer(minLength: 60) }
        }
    }
    
    private var messageText: String {
        // 如果你的模型没有 isStreaming 属性，可以直接返回 message.text
        if message.text.isEmpty && message.isStreaming {
            return "..."
        }
        return message.text
    }

    private var background: AnyShapeStyle {
        if isUser {
            return AnyShapeStyle(Color.accentColor)
        } else {
            return AnyShapeStyle(Color(.systemGray5))
        }
    }

    private var foreground: Color {
        isUser ? .white : .primary
    }
}
