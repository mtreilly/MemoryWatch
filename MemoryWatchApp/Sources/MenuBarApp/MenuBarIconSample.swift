import SwiftUI

#if MENU_BAR_ICON_SAMPLE

/// Minimal standalone app that renders the MemoryWatch menu bar glyph.
/// Build with `-DMENU_BAR_ICON_SAMPLE` to try it out without touching the main target.
@main
struct MemoryWatchIconSampleApp: App {
    var body: some Scene {
        WindowGroup("Menu Bar Icon Sample") {
            VStack(spacing: 20) {
                MemoryWatchMenuBarGlyph()
                    .frame(width: 48, height: 48)
                Text("MemoryWatch Menu Bar Icon")
                    .font(.headline)
                MemoryWatchMenuBarGlyph()
                    .frame(width: 24, height: 24)
                    .help("24px preview for menu bar scale")
            }
            .padding(24)
            .frame(minWidth: 220)
        }
    }
}
#endif

struct MemoryWatchMenuBarGlyph: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color.blue.opacity(0.85), Color.purple.opacity(0.9)], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                )
            VStack(spacing: 2) {
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(height: 3)
                    .padding(.horizontal, 6)
                HStack(spacing: 3) {
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 4, height: 10)
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 4, height: 14)
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 4, height: 18)
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 4, height: 12)
                }
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(height: 3)
                    .padding(.horizontal, 6)
            }
            .padding(.vertical, 4)
        }
        .shadow(color: Color.black.opacity(0.15), radius: 2, x: 0, y: 1)
    }
}

#if DEBUG
struct MemoryWatchMenuBarGlyph_Previews: PreviewProvider {
    static var previews: some View {
        MemoryWatchMenuBarGlyph()
            .frame(width: 48, height: 48)
            .previewDisplayName("MemoryWatch Glyph Preview")
    }
}
#endif
