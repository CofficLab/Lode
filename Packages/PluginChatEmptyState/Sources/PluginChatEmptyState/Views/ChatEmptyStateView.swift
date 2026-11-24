import LumiUI
import ProviderPromptSuggestion
import SwiftUI

/// 聊天空态：图标 + 标题 + 可点击的示例提示。
///
/// 示例来自宿主的 `PromptSuggestionProviding`；点击后交给
/// `PromptSuggestionExecuting` 直接发送，领域上下文由宿主注入。
@MainActor
struct ChatEmptyStateView: View {
    @LumiTheme private var theme

    let suggestions: [PromptSuggestion]
    let onSelect: (PromptSuggestion) -> Void

    @State private var pendingSuggestionID: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                atmosphere

                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        heroIcon

                        Text(pluginLocalization.string("How can I help with your database?"))
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 18)

                        Text(pluginLocalization.string("Ask about your schema, draft SQL, or explain a query."))
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 8)

                        if !suggestions.isEmpty {
                            VStack(spacing: 8) {
                                ForEach(suggestions) { suggestion in
                                    suggestionButton(for: suggestion)
                                }
                            }
                            .frame(maxWidth: 440)
                            .padding(.top, 26)
                        }
                    }
                    .frame(maxWidth: 560)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: max(320, proxy.size.height - 24)
                    )
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("lode.chat.empty-state")
        }
        .background(theme.background)
    }

    private var heroIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.primary.opacity(0.12))
                .frame(width: 56, height: 56)

            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(theme.primary)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.primary.opacity(0.18), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private func suggestionButton(for suggestion: PromptSuggestion) -> some View {
        Button {
            guard pendingSuggestionID == nil else { return }
            pendingSuggestionID = suggestion.id
            onSelect(suggestion)
        } label: {
            SuggestionRow(
                suggestion: suggestion,
                isPending: pendingSuggestionID == suggestion.id
            )
        }
        .buttonStyle(.plain)
        .disabled(pendingSuggestionID != nil)
        .accessibilityIdentifier("lode.chat.empty-state.suggestion.\(suggestion.id)")
    }

    private var atmosphere: some View {
        GeometryReader { geometry in
            let maxRadius = max(geometry.size.width, geometry.size.height)

            RadialGradient(
                gradient: Gradient(colors: [
                    theme.primary.opacity(0.06),
                    theme.primary.opacity(0.02),
                    theme.background.opacity(0)
                ]),
                center: .center,
                startRadius: 0,
                endRadius: maxRadius * 0.8
            )
            .ignoresSafeArea()
        }
    }
}

@MainActor
private struct SuggestionRow: View {
    @LumiTheme private var theme

    let suggestion: PromptSuggestion
    let isPending: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: suggestion.systemImage ?? "sparkles")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.primary)
                .frame(width: 26, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(theme.primary.opacity(0.12))
                }

            Text(suggestion.title)
                .font(.appBody)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if isPending {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.up.forward")
                    .font(.appCaption)
                    .foregroundStyle(theme.textTertiary)
                    .opacity(isHovered ? 1 : 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered ? theme.primary.opacity(0.08) : theme.surface.opacity(0.65))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isHovered ? theme.primary.opacity(0.32) : theme.divider,
                    lineWidth: 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovered = $0 }
    }
}