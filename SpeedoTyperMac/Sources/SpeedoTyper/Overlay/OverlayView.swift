import SwiftUI

@MainActor
final class OverlayModel: ObservableObject {
    @Published var typed: String = ""
    @Published var remaining: String = ""
    @Published var hint: String = "Tab ⇥"
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 10) {
            if !model.typed.isEmpty {
                Text(model.typed).foregroundStyle(.white)
            }
            Text(model.remaining).foregroundStyle(Color(white: 0.55))
            Text(model.hint)
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color(white: 0.17))
                .foregroundStyle(Color(white: 0.78))
                .cornerRadius(4)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(white: 0.11).opacity(0.96))
        .cornerRadius(6)
    }
}
