import SwiftUI

struct WelcomeView: View {
    var openWebLink: () -> Void = {}
    @State private var showDeveloperPairing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.left.arrow.right.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.accentColor.gradient)
                    Text("Connect your Android phone")
                        .font(.largeTitle.bold())
                    Text("No app to install and no Developer mode. Just a cable, or your phone's browser.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(alignment: .top, spacing: 16) {
                    card(
                        title: "With a USB cable",
                        subtitle: "Browse, read and copy everything",
                        icon: "cable.connector",
                        steps: [
                            "Plug the phone into this Mac and unlock it.",
                            "Pull down the notification shade and tap the **USB** notification (“Charging this device via USB”).",
                            "Choose **File transfer**. The phone appears here in a few seconds.",
                        ])
                    card(
                        title: "Over Wi-Fi",
                        subtitle: "Send and receive with the phone's browser",
                        icon: "qrcode",
                        steps: [
                            "Put the phone and Mac on the same Wi-Fi network.",
                            "Open **Browser Link** and scan the QR code with the phone's camera.",
                            "Send photos and files to the Mac, or save files shared from the Mac.",
                        ],
                        action: ("Open Browser Link", openWebLink))
                }
                .frame(maxWidth: 820)

                VStack(spacing: 6) {
                    Text("Want to browse the phone over Wi-Fi too?")
                        .font(.callout.weight(.semibold))
                    Text("That needs Android's Wireless debugging, which is in Developer options.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Set Up Developer Mode over Wi-Fi…") { showDeveloperPairing = true }
                        .buttonStyle(.link)
                }
                .multilineTextAlignment(.center)
            }
            .padding(36)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Tether")
        .sheet(isPresented: $showDeveloperPairing) { WirelessConnectView() }
    }

    private func card(title: String, subtitle: String, icon: String, steps: [LocalizedStringKey], action: (String, () -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: icon).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                    Text(step).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
            Spacer(minLength: 0)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct DeviceStateView: View {
    let device: Device

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        }
        .navigationTitle(device.displayName)
    }

    private var title: String {
        if device.kind == .mtp { return "Another app is using your phone" }
        switch device.state {
        case "unauthorized": return "Allow access on your phone"
        case "offline": return "Phone is offline"
        default: return "Can't access this phone yet"
        }
    }

    private var icon: String {
        device.state == "unauthorized" ? "lock.iphone" : "exclamationmark.triangle"
    }

    private var message: String {
        if device.kind == .mtp {
            return "Quit Android File Transfer, OpenMTP, Image Capture or Photos if they're open, then unplug the phone and plug it back in. Tether will pick it up automatically."
        }
        switch device.state {
        case "unauthorized":
            return "Unlock your phone and tap “Allow” on the “Allow USB debugging?” prompt. Tick “Always allow from this computer” to skip this next time.\n\nNo prompt? Unplug and reconnect the cable, or turn USB debugging off and on again."
        case "offline":
            return "Reconnect the cable, or turn USB debugging off and on again in Developer options."
        default:
            return "The phone reports “\(device.state)”. Try reconnecting it."
        }
    }
}

struct SettingsView: View {
    @AppStorage(AppSettings.downloadFolderKey) private var downloadFolder = ""

    var body: some View {
        Form {
            LabeledContent("Save downloads to") {
                HStack {
                    Text(AppSettings.downloadFolder.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        panel.directoryURL = AppSettings.downloadFolder
                        if panel.runModal() == .OK, let url = panel.url {
                            downloadFolder = url.path
                        }
                    }
                }
            }
            Section("Developer mode (optional)") {
                LabeledContent("adb in use") {
                    Text(ADBTool.executableURL?.path ?? "Not found")
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical)
    }
}
