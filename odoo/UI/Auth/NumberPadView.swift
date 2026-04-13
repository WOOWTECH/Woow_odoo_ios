import SwiftUI

/// Reusable numeric keypad for PIN entry screens.
/// Used by both PinView (unlock) and PinSetupView (setup/change PIN).
struct NumberPadView: View {
    let onNumberTap: (String) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 28) {
                    ForEach(1...3, id: \.self) { col in
                        let number = row * 3 + col
                        numberKey("\(number)")
                    }
                }
            }
            HStack(spacing: 28) {
                Spacer().frame(width: 76, height: 76)
                numberKey("0")
                deleteKey
            }
        }
    }

    private func numberKey(_ number: String) -> some View {
        Button {
            onNumberTap(number)
        } label: {
            Text(number)
                .font(.title)
                .fontWeight(.medium)
                .frame(width: 76, height: 76)
                .background(Color(.systemGray6))
                .clipShape(Circle())
        }
        .foregroundStyle(.primary)
    }

    private var deleteKey: some View {
        Button {
            onDelete()
        } label: {
            Image(systemName: "delete.backward")
                .font(.title2)
                .frame(width: 76, height: 76)
        }
        .foregroundStyle(.primary)
    }
}
