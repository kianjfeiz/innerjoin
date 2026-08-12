import SwiftUI

/// The 44pt strip across the whole top of the window. The real traffic lights sit in it
/// (the window has no title bar), and it doubles as the drag region — design D runs it
/// full width, above both the rail and the content.
struct TitleStrip: View {
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            // Space the system's own traffic lights occupy — nothing is drawn here.
            Spacer()
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(palette.strip)
        .overlay(alignment: .bottom) { Hairline(neutral: true) }
    }
}
