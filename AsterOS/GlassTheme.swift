import SwiftUI

struct AsterBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduced
    var body: some View {
        ZStack {
            DockTheme.background
            if !reduced {
                RadialGradient(colors: [.mint.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 520)
                RadialGradient(colors: [.indigo.opacity(0.18), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 600)
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}
struct AsterGlass: ViewModifier {
    var radius: CGFloat = 34
    @Environment(\.accessibilityReduceTransparency) private var reduced
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        if reduced || contrast == .increased {
            content.background(DockTheme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}
extension View {
    func asterGlass(radius: CGFloat = 34) -> some View { modifier(AsterGlass(radius: radius)) }
}
struct AsterControlStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduced
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduced { content.buttonStyle(.glass) }
        else { content.buttonStyle(.bordered) }
    }
}
struct AsterTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.padding(.horizontal, 18).padding(.vertical, 14)
            .background(.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
// Open sections retain native controls and accessibility without opaque Form boxes.
struct GlassForm<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                ForEach(sections: content) { section in
                    VStack(alignment: .leading, spacing: 14) {
                        section.header.font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(subviews: section.content) { row in
                                row.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        section.footer.font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(24).frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
        .background { AsterBackdrop() }
        .textFieldStyle(AsterTextFieldStyle())
        .modifier(AsterControlStyle()).buttonBorderShape(.capsule)
        .controlSize(.large).pickerStyle(.menu)
        .scrollDismissesKeyboard(.interactively)
    }
}
