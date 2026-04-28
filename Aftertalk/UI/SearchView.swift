import SwiftUI

/// Cross-meeting search surface. Stub for now — Day 6 fills in semantic /
/// verbatim / people / decisions modes. Empty state matches Quiet Studio
/// "nothing to find yet" voice so the placeholder doesn't read like a bug.
struct SearchView: View {
    @Environment(\.atPalette) private var palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            palette.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 40)
                empty
                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .navigationBarHidden(true)
        .atTheme()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 14, weight: .medium))
                    Text("Meetings")
                        .font(.atBody(13, weight: .medium))
                }
                .foregroundStyle(palette.mute)
            }
            .buttonStyle(.plain)
            .padding(.top, AT.Space.safeTop)

            QSEyebrow("Search", color: palette.faint)
            QSTitle(text: "Across every meeting", size: 28, tracking: -0.6, color: palette.ink)
                .padding(.bottom, 4)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.mute)
                Text("Try “what did Sara say about audit”")
                    .font(.atBody(14))
                    .foregroundStyle(palette.faint)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: AT.Radius.base * 1.2, style: .continuous)
                    .fill(palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: AT.Radius.base * 1.2, style: .continuous)
                            .stroke(palette.line, lineWidth: 0.5)
                    )
            )
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            QSEyebrow("Coming on day 6", color: palette.faint)
            QSBody(text: "Cross-meeting recall plugs into the same retrieval pipeline that powers Ask. Until then, search lives inside each meeting’s detail view.",
                   color: palette.mute)
        }
    }
}
