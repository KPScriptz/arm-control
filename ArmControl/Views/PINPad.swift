import SwiftUI

/// PIN entry for leaving attendant mode. Modelled on the iOS passcode screen: dots, a circular
/// keypad, no hint, no "forgot PIN", and no way to tell a wrong entry from a locked-out one beyond
/// the message it chooses to show.
struct PINPad: View {
    @StateObject private var kiosk = Kiosk.shared
    var onSuccess: () -> Void
    var onCancel: () -> Void

    @State private var entry = ""
    @State private var shake = 0
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let keys: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "⌫"]]

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                Image(systemName: "lock.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.secondary)

                Text("Enter operator PIN")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.label)

                dots

                Text(kiosk.isCoolingOff
                     ? "Too many attempts — wait \(kiosk.coolOffRemaining)s"
                     : " ")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.bad)
                    .contentTransition(.numericText())

                keypad

                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.body)
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 4)

                Spacer()
            }
            .frame(maxWidth: 360)
        }
        .onReceive(tick) { now = $0 }
        // The shake already says "wrong" to the eye. This says it to the hand, which is how every
        // Apple passcode field behaves and the reason a wrong entry never needs reading.
        .sensoryFeedback(.error, trigger: shake)
    }

    private var dots: some View {
        HStack(spacing: 18) {
            ForEach(0..<max(4, entry.count), id: \.self) { i in
                Circle()
                    .fill(i < entry.count ? Theme.label : Color.clear)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(Theme.secondary, lineWidth: 1.2))
            }
        }
        .modifier(Shake(animatableData: CGFloat(shake)))
    }

    private var keypad: some View {
        VStack(spacing: 18) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 22) {
                    ForEach(row, id: \.self) { key in
                        if key.isEmpty {
                            Color.clear.frame(width: 76, height: 76)
                        } else {
                            Button { press(key) } label: {
                                Group {
                                    if key == "⌫" {
                                        Image(systemName: "delete.left")
                                            .font(.title2)
                                    } else {
                                        Text(key)
                                            .font(.system(size: 32, weight: .regular, design: .rounded))
                                    }
                                }
                                .foregroundStyle(Theme.label)
                                .frame(width: 76, height: 76)
                                .pivotGlass(in: Circle(),
                                            tint: key == "⌫" ? nil : nil,
                                            interactive: key != "⌫")
                            }
                            .buttonStyle(.plain)
                            .disabled(kiosk.isCoolingOff)
                        }
                    }
                }
            }
        }
        .pivotGlassGroup()
        .opacity(kiosk.isCoolingOff ? 0.35 : 1)
        .animation(.default, value: kiosk.isCoolingOff)
    }

    private func press(_ key: String) {
        if key == "⌫" {
            if !entry.isEmpty { entry.removeLast() }
            return
        }
        guard entry.count < 8 else { return }
        entry += key

        // Submit as soon as the entry is long enough, so the usual 4-digit PIN needs no Enter key.
        guard entry.count >= kiosk.pin.count else { return }
        if kiosk.tryUnlock(entry) {
            onSuccess()
        } else {
            withAnimation(.default) { shake += 1 }
            entry = ""
        }
    }
}

private struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: sin(animatableData * .pi * 4) * 10, y: 0))
    }
}
