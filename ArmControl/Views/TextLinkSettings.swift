import SwiftUI

/// Setting up the text-a-link path: the Twilio account, the message, and a test send.
///
/// Reached from Delivery, because it is the same job as the QR — getting the clip onto a phone —
/// and it should be set up next to it.
struct TextLinkSettings: View {
    @StateObject private var text = TextDelivery.shared
    @StateObject private var delivery = DeliveryServer.shared

    @State private var sid = ""
    @State private var token = ""
    @State private var from = ""
    @State private var testNumber = ""
    @State private var result: String?
    @State private var resultIsGood = false
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle("Offer “Text it to me”", isOn: $text.enabled)
            } footer: {
                Text(text.isConfigured
                     ? "Adds a button to the guest result screen, beside the QR."
                     : "The button stays hidden until an account is filled in below — a dead button on the guest screen is worse than none.")
            }

            // ⚠️ The single most important thing on this screen, and it is stated before the
            // account fields rather than after them.
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("A texted link still only opens on the venue Wi-Fi")
                            .font(.subheadline.weight(.semibold))
                        Text("Clips are served off this iPad at \(delivery.host ?? "its local address"), so the link is dead the moment a guest leaves the network. Texting fixes a QR that would not scan; it does not make the clip reachable from home.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                    }
                } icon: {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundStyle(Theme.warn)
                }
            }

            Section {
                LabeledContent("Account SID") {
                    TextField("AC…", text: $sid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Auth token") {
                    SecureField(TextDelivery.authToken.isEmpty ? "Required" : "••••••••",
                                text: $token)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Send from") {
                    TextField("+1…", text: $from)
                        .keyboardType(.phonePad)
                        .multilineTextAlignment(.trailing)
                }
                Button {
                    text.setAccount(sid: sid, token: token, from: from)
                    token = ""                       // never leave it sitting in a field
                    // Show what was actually stored, not what was typed — the number is
                    // normalised to E.164 on the way in, and the field disagreeing with the
                    // footer underneath it invites a second, unnecessary edit.
                    from = TextDelivery.fromNumber
                    result = "Saved."
                    resultIsGood = true
                } label: {
                    Label("Save account", systemImage: "checkmark.circle")
                }
                .disabled(sid.isEmpty || token.isEmpty || from.isEmpty)

                if text.isConfigured {
                    Button(role: .destructive) { confirmClear = true } label: {
                        DestructiveLabel("Remove the account", systemImage: "trash")
                    }
                }
            } header: {
                Text("Twilio account")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(text.isConfigured
                         ? "Configured. Sending from \(TextDelivery.fromNumber)."
                         : "From console.twilio.com — Account SID, Auth Token, and a number you own.")
                        .foregroundStyle(text.isConfigured ? Theme.good : Theme.secondary)
                    // Same rule as the PLC password, same reason.
                    Text("All three are kept in the Keychain, never written to a log, and deliberately **not** included in an exported event setup — those get AirDropped and emailed, and an account that can send messages on your bill has no business travelling inside one.")
                    Text("On a Twilio trial only verified numbers can be texted, and every message is prefixed with a trial notice.")
                }
                .font(.footnote)
            }

            Section {
                TextEditor(text: $text.template)
                    .frame(minHeight: 96)
                    .font(.body)
                Button {
                    text.template = TextDelivery.defaultTemplate
                } label: {
                    Label("Reset the wording", systemImage: "arrow.counterclockwise")
                }
            } header: {
                Text("Message")
            } footer: {
                Text("`{link}` is replaced with the guest's link. Leave it out and the link is added on the end instead — a message that dropped it silently would be the worst possible edit.")
            }

            Section {
                LabeledContent("Test number") {
                    TextField("(555) 123-4567", text: $testNumber)
                        .keyboardType(.phonePad)
                        .multilineTextAlignment(.trailing)
                }
                Button {
                    Task { await sendTest() }
                } label: {
                    HStack {
                        Label("Send a test", systemImage: "paperplane")
                        if text.sending { Spacer(); ProgressView() }
                    }
                }
                .disabled(!text.isConfigured || TextDelivery.e164(testNumber) == nil || text.sending)

                if let result {
                    Text(result)
                        .font(.footnote)
                        .foregroundStyle(resultIsGood ? Theme.good : Theme.bad)
                }
            } header: {
                Text("Check it")
            } footer: {
                Text(delivery.running
                     ? "Sends the real message, with a real link to the most recent clip if there is one. Do this once before the doors open — a texting account that turns out to be wrong is found at the worst possible moment otherwise."
                     : "Delivery is off, so there is no link to send. Turn it on first.")
            }
        }
        .navigationTitle("Text the link")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // The token is never read back into the field — it is write-only from here on.
            sid = TextDelivery.accountSID
            from = TextDelivery.fromNumber
        }
        .confirmationDialog("Remove the texting account?",
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                text.clearAccount()
                sid = ""; from = ""; token = ""
                result = "Removed."
                resultIsGood = false
            }
        } message: {
            Text("The SID, token and number are deleted from the Keychain on this iPad.")
        }
    }

    private func sendTest() async {
        result = nil
        // Prefer a real published clip so the test proves the whole path, not just Twilio.
        guard let link = DeliveryServer.shared.checkURL else {
            result = "No address yet — join the venue Wi-Fi."
            resultIsGood = false
            return
        }
        do {
            try await text.send(link: link, to: testNumber)
            result = "Sent. Open it on that phone to confirm the link works too."
            resultIsGood = true
        } catch {
            result = error.localizedDescription
            resultIsGood = false
        }
    }
}
