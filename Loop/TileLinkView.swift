import SwiftUI

struct UnusedTileLinkView: View {
    struct Destination {
        var deeplink: URL
    }

    // Inputs required by the view. Defaults provided for preview/testing only.
    var destination: Destination
    var active: Bool
    var icon: AnyView

    var body: some View {
        Link(destination: destination.deeplink) {
            if #available(iOS 26.0, *) {
                icon
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .foregroundColor(foregroundColor(active: active))
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
            } else {
                icon
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .foregroundColor(foregroundColor(active: active))
                    .background(backgroundColor(active: active))
                    .clipShape(ContainerRelativeShape())
            }
        }
    }

    // MARK: - Helpers
    private func foregroundColor(active: Bool) -> Color {
        active ? .white : .primary
    }

    private func backgroundColor(active: Bool) -> Color {
        active ? .blue : Color(.secondarySystemBackground)
    }
}

#Preview {
    UnusedTileLinkView(
        destination: .init(deeplink: URL(string: "https://example.com")!),
        active: true,
        icon: AnyView(Image(systemName: "bolt.fill").font(.largeTitle))
    )
}
