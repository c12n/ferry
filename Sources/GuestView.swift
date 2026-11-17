import SwiftUI
import UIKit

/// One-time guest passes, on the main screen: make one, see the ones still out
/// there, take one back. A pass is a device like any other once used; while unused
/// it is a code with a deadline, and its key lives in memory only (see Model).
struct GuestPassSection: View {
    @ObservedObject var model: Model
    @State private var shownPass: WireGuardSetup.Peer?

    private var passes: [WireGuardSetup.Peer] {
        model.wireGuardPeers.filter { $0.guestPass != nil }
    }

    var body: some View {
        Section {
            ForEach(passes) { peer in
                if let pass = peer.guestPass {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.name)
                            Text(pass.consumedAt != nil
                                 ? "Used · access ends \(Format.dateTime(pass.accessExpiresAt))"
                                 : "Not used · code expires \(Format.dateTime(pass.qrExpiresAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if pass.consumedAt == nil {
                            if model.guestKeyIDs.contains(peer.id) {
                                Button("Show code") { shownPass = peer }
                                    .font(.subheadline)
                            }
                            Button("Revoke", role: .destructive) { model.revokeGuestPass(peer) }
                                .font(.subheadline)
                        }
                    }
                }
            }
            Button {
                shownPass = model.createGuestPass()
            } label: {
                Label("New one-time guest code", systemImage: "qrcode")
            }
            .disabled(model.wireGuardPeers.filter { $0.guestPass != nil && $0.guestPass?.consumedAt == nil }.count >= Model.maxUnusedGuestPasses)
            .accessibilityIdentifier("guest.new")
        } header: {
            Text("Guest passes")
        } footer: {
            Text("A guest code works once, for one device, and only for 10 minutes. Whoever uses it gets 4 hours of access. The code can't be shown again once its screen is closed, and a code that lapses unused can never be used.")
        }
        .sheet(item: $shownPass) { peer in
            GuestQRView(model: model, peer: peer)
        }
    }
}

/// The guest code itself, while it can still be shown: the QR code, its countdown,
/// and the ways out. The code is blanked while the screen is being captured or
/// recorded, and after a screenshot the person is offered a fresh code, since the
/// old one may now be in a photo. Closing this screen forgets the key for good.
struct GuestQRView: View {
    @ObservedObject var model: Model
    let peer: WireGuardSetup.Peer
    @Environment(\.dismiss) private var dismiss
    @State private var captured = UIScreen.main.isCaptured
    @State private var tookScreenshot = false
    @State private var replacement: WireGuardSetup.Peer?

    private var pass: WireGuardSetup.GuestPass? { peer.guestPass }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                List {
                    Section {
                        if captured {
                            Label("The code is hidden while the screen is captured or recorded.", systemImage: "eye.slash")
                                .accessibilityIdentifier("guest.hidden")
                        } else if let config = model.guestConfig(for: peer), let qr = QRCode.image(config) {
                            Image(uiImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 240)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .accessibilityLabel("One-time guest QR code")
                                .accessibilityIdentifier("guest.qr")
                        } else {
                            Label("This code can no longer be shown. Make a new one.", systemImage: "exclamationmark.triangle")
                        }
                    }
                    if let pass {
                        Section {
                            LabeledContent("Code expires", value: Format.dateTime(pass.qrExpiresAt))
                            LabeledContent("Time left", value: Format.remaining(until: pass.qrExpiresAt, now: context.date))
                            LabeledContent("Access after use", value: "4 hours, until \(Format.dateTime(pass.accessExpiresAt))")
                        }
                    }
                    if tookScreenshot {
                        Section {
                            Text("You took a screenshot. If the code is in it, anyone with the photo can use it first.")
                            Button("Replace this code with a new one") {
                                replacement = model.regenerateGuestPass(peer)
                            }
                            .accessibilityIdentifier("guest.regenerate")
                        }
                    }
                    Section {
                        Button("Revoke this pass", role: .destructive) {
                            model.revokeGuestPass(peer)
                            dismiss()
                        }
                        .accessibilityIdentifier("guest.revoke")
                    }
                }
            }
            .navigationTitle("One-time guest code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            captured = UIScreen.main.isCaptured
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            tookScreenshot = true
        }
        .onChange(of: replacement) { _, newValue in
            if newValue != nil { dismiss() }
        }
        .onDisappear {
            model.discardGuestKey(peer.id)
        }
    }
}
