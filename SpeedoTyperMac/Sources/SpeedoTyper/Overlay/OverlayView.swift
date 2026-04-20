import SwiftUI
import AppKit

@MainActor
final class OverlayModel: ObservableObject {
    @Published var remaining: String = ""
    @Published var font: NSFont = .systemFont(ofSize: 13)
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    var body: some View {
        Text(model.remaining)
            .font(Font(model.font))
            .foregroundStyle(Color(white: 0.55))
            .fixedSize(horizontal: true, vertical: false)
    }
}
