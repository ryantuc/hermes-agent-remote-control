import SwiftUI
import UIKit

/// Settings → Appearance: the desktop skins by name, the polarity segment, the follow-backend subscription, and the Dynamic Type pointer; skin choice is client-local and never writes to the backend, which would repaint every connected client.
/// Everything here reads `theme.effectiveSkinName`, never `localSkinName`: the two differ while Follow is on, and showing the local one is BUG-046.
@MainActor
struct AppearanceSettingsView: View {
    @Environment(\.hermes) private var t
    @Environment(Theme.self) private var theme
    /// Resolved by `HermesThemeContainer`, so it already reflects the polarity segment on this very screen and the swatches preview in the polarity the app is actually in.
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        @Bindable var theme = theme

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SectionHeader("Skin")
                skinGrid
                    .padding(.horizontal, Space.s6)
                    .padding(.bottom, Space.s6)
                backendSkinRow

                SectionHeader("Appearance")
                SegmentedRow(
                    options: Theme.Polarity.allCases,
                    selection: $theme.polarityPreference
                ) { option in
                    switch option {
                    case .system: return "System"
                    case .light: return "Light"
                    case .dark: return "Dark"
                    }
                }
                .padding(.horizontal, Space.s6)
                .padding(.bottom, Space.s5)

                SwitchRow(
                    "Follow backend skin",
                    subtitle: "Repaints when the backend broadcasts a skin change. Selecting a skin above never repaints your other clients.",
                    isOn: $theme.followBackendSkin
                )

                SectionHeader("Text size")
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    FlatRow {
                        VStack(alignment: .leading, spacing: Space.s1) {
                            Text("Text size")
                                .font(HermesFont.callout)
                                .foregroundStyle(t.text1)
                            Text("Follows Dynamic Type. Change it in iOS Settings → Display & Brightness.")
                                .font(HermesFont.footnote)
                                .foregroundStyle(t.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } trailing: {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(t.text4)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Text size. Opens iOS Settings.")
            }
            .padding(.bottom, Space.s10)
        }
        .background(t.canvas)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(t.canvas, for: .navigationBar)
    }

    // MARK: Skin grid — 2 across

    private var skinGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s4), GridItem(.flexible())], spacing: Space.s4) {
            ForEach(SkinPreset.all) { preset in
                skinCard(preset)
            }
        }
    }

    /// Shown only when the backend is painting a skin that has no card here, which is the ordinary case: only `mono` and `slate` share a name with a desktop theme.
    @ViewBuilder
    private var backendSkinRow: some View {
        let name = theme.effectiveSkinName
        if theme.followBackendSkin, !name.isEmpty, SkinPreset.named(name) == nil {
            FlatRow {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text("Backend · \(theme.effectiveSkinLabel)")
                        .font(HermesFont.calloutStrong)
                        .foregroundStyle(t.text1)
                    Text("This backend's skin has no card here, so it is being adapted rather than matched.")
                        .font(HermesFont.footnote)
                        .foregroundStyle(t.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(t.action)
            }
            .accessibilityLabel("Backend skin \(theme.effectiveSkinLabel), selected")
        }
    }

    private func swatch(_ preset: SkinPreset) -> HermesSkin {
        scheme == .dark ? preset.dark : preset.light
    }

    private func skinCard(_ preset: SkinPreset) -> some View {
        let isSelected = theme.effectiveSkinName == preset.name
        return Button {
            // One operation: record the choice and take the source back from the backend, because writing only the name leaves a card selectable while the screen never changes.
            theme.selectLocalSkin(preset.name)
            HapticFeedback.selection()
        } label: {
            VStack(alignment: .leading, spacing: Space.s3) {
                // The dot is the skin's accent rather than Desktop's foreground, because the accent is the one seed distinct for every theme in both polarities and a foreground dot makes Light ten white cards with ten black dots.
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(swatch(preset).bg.color)
                    .frame(height: 56)
                    .overlay(alignment: .bottomLeading) {
                        Circle()
                            .fill(swatch(preset).accent.color)
                            .frame(width: 12, height: 12)
                            .padding(Space.s4)
                    }
                Text(preset.label)
                    .font(HermesFont.calloutStrong)
                    .foregroundStyle(t.text1)
                Text(preset.blurb)
                    .font(HermesFont.footnote)
                    .foregroundStyle(t.text3)
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(Space.s4)
            .background(
                isSelected ? t.fill3 : t.fill1,
                in: RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.enclosure, style: .continuous)
                    .strokeBorder(isSelected ? t.stroke1 : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.label) skin\(isSelected ? ", selected" : "")")
    }
}
