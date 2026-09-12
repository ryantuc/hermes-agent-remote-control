import SwiftUI
import UIKit

/// A circle holding either a profile's avatar or one letter of its display name, used by the bot roster row and the bot thread header.
///
/// The chip never fetches; bytes arrive as `imageData` from whatever cached them, because a view that fetches in its own body refetches on every recomposition.
@MainActor
struct IdentityChip: View {
    @Environment(\.hermes) private var t

    /// The roster row's diameter — the size this component was drawn against.
    static let rosterSize: CGFloat = 34
    /// The thread header's diameter.
    static let headerSize: CGFloat = 24

    /// The name the initial is derived from when there is no image.
    let displayName: String
    /// The avatar bytes, when this identity has one and it has been fetched.
    var imageData: Data?
    /// Diameter, deliberately not scaled by Dynamic Type: it is an image well, and the row grows around it from the type stack beside it.
    var size: CGFloat

    init(displayName: String, imageData: Data? = nil, size: CGFloat = IdentityChip.rosterSize) {
        self.displayName = displayName
        self.imageData = imageData
        self.size = size
    }

    /// The one letter drawn when there is no avatar: the first character of the trimmed name, uppercased, or `"?"` when the name is empty.
    static func initial(for displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    /// One rung of the ladder, picked by diameter. Nothing here is a literal size.
    private var initialStyle: HermesTextStyle {
        size >= 30 ? HermesFont.calloutStrong : HermesFont.footnote
    }

    var body: some View {
        ZStack {
            Circle().fill(t.accentFill)
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Text(Self.initial(for: displayName))
                    .font(initialStyle)
                    .foregroundStyle(t.accent)
                    .lineLimit(1)
                    // The circle is a fixed well, so the letter shrinks rather than pushing it open.
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, Space.s1)
            }
        }
        .frame(width: size, height: size)
        // The row beside it already reads the name out.
        .accessibilityHidden(true)
    }
}
