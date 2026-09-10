import SwiftUI

/// Where a guest types their number to be texted the clip.
///
/// 🔑 **A guest is using this, standing up, once, with a queue behind them.** So: a big keypad
/// rather than a keyboard (no autocorrect, no shifting layout, no numeric row to find), the number
/// formatted as it is typed so a mistyped digit is visible, and exactly one thing to press when
/// done. It deliberately looks like the PIN pad — same shapes, same rhythm — because that keypad is
/// already proven at arm's length on this iPad.
///
/// ⚠️ **Nothing here is remembered.** The digits live in `@State` for the life of this view. See
/// the note in `TextDelivery` — a booth that accumulates an evening of phone numbers is holding
/// personal data nobody agreed to.
struct PhonePad: View {
    let link: URL
    var onDone: () -> Void

    @StateObject private var text = TextDelivery.shared
    @State private var digits = ""
    @State private var error: String?
    @State private var sent = false
    @State private var shake = 0

    private let keys: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["+", "0", "⌫"]]

    private var canSend: Bool { TextDelivery.e164(digits) != nil && !text.sending }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if sent { confirmation } else { entry }
        }
        .sensoryFeedback(.error, trigger: shake)
        .sensoryFeedback(.success, trigger: sent)
    }

    // MARK: Entry

    private var entry: some View {
        VStack(spacing: 26) {
            Spacer()

            Image(systemName: "message.fill")
                .font(.title)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.secondary)

            Text("Text me the link")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.label)

            Text(digits.isEmpty ? "Your mobile number" : TextDelivery.pretty(digits))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(digits.isEmpty ? Theme.tertiary : Theme.label)
                .frame(height: 44)
                .contentTransition(.numericText())

            Text(error ?? " ")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.bad)
                .multilineTextAlignment(.center)
                .frame(height: 34)

            keypad

            Button {
                Task { await send() }
            } label: {
                Group {
                    if text.sending {
                        ProgressView().tint(.black)
                    } else {
                        Label("Send", systemImage: "paperplane.fill")
                            .font(.title3.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 58)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .foregroundStyle(.black)
            .buttonBorderShape(.roundedRectangle(radius: Theme.controlRadius))
            .disabled(!canSend)

            Button("Not now", action: onDone)
                .buttonStyle(.plain)
                .font(.body)
                .foregroundStyle(Theme.accent)

            // Said here as well as in the message, because this is the moment the guest can still
            // act on it — they are standing on the venue Wi-Fi right now.
            Text("The link opens on the venue Wi-Fi. Have a look before you head off.")
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 2)

            Spacer()
        }
        .frame(maxWidth: 380)
        .padding(.horizontal, 24)
    }

    private var keypad: some View {
        VStack(spacing: 16) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 22) {
                    ForEach(row, id: \.self) { key in
                        Button { press(key) } label: {
                            Text(key)
                                .font(.system(size: 30, weight: .regular, design: .rounded))
                                .foregroundStyle(Theme.label)
                                .frame(width: 76, height: 76)
                                .background(Theme.fill, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(key == "⌫" && digits.isEmpty)
                        .opacity(key == "⌫" && digits.isEmpty ? 0.35 : 1)
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: digits)
    }

    private func press(_ key: String) {
        error = nil
        switch key {
        case "⌫": if !digits.isEmpty { digits.removeLast() }
        case "+": if digits.isEmpty { digits = "+" }   // only ever a prefix
        default:  if digits.filter(\.isNumber).count < 15 { digits += key }
        }
    }

    private func send() async {
        do {
            try await text.send(link: link, to: digits)
            sent = true
            // Long enough to read, short enough that the queue does not notice.
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            onDone()
        } catch {
            self.error = error.localizedDescription
            shake &+= 1
        }
    }

    // MARK: Sent

    private var confirmation: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.good)
            Text("Sent")
                .font(.title.weight(.semibold))
                .foregroundStyle(Theme.label)
            Text("Check your messages.")
                .font(.body)
                .foregroundStyle(Theme.secondary)
        }
    }
}
