import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A Ferry backup file, encrypted or plain. Declared in the app's Info.plist as
    /// an exported type (see project.yml).
    static let ferryBackup = UTType(exportedAs: "com.c12n.tether.backup")
}

/// A document wrapper for the exporter: the backup's bytes, nothing more.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.ferryBackup, .json, .data] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Backup and restore. The full backup holds the server key and the devices' keys,
/// so the export the screen offers first is encrypted with a password the person
/// chooses (see Backup.swift: PBKDF2 and AES-GCM; Ferry never sees a copy anywhere
/// else). A plain export holds settings and device names only, and restoring it
/// restores only settings. Restoring a full backup replaces the setup wholesale:
/// there is no merge, because two setups can't share one server key's devices.
struct BackupView: View {
    @ObservedObject var model: Model
    @State private var password = ""
    @State private var passwordAgain = ""
    @State private var exportDocument: BackupDocument?
    @State private var exportEncrypted = true
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var pendingImport: Data?
    @State private var importPassword = ""
    @State private var needsPassword = false
    @State private var confirmRestore: FerryBackup?
    @State private var message: String?

    var body: some View {
        List {
            Section {
                SecureField("Backup password", text: $password)
                    .textContentType(.newPassword)
                    .accessibilityIdentifier("backup.password")
                SecureField("Password again", text: $passwordAgain)
                    .textContentType(.newPassword)
                Button("Export encrypted backup") { prepareExport(encrypted: true) }
                    .disabled(password.count < 8 || password != passwordAgain)
                    .accessibilityIdentifier("backup.exportEncrypted")
                Button("Export settings only, no keys") { prepareExport(encrypted: false) }
                    .accessibilityIdentifier("backup.exportPlain")
            } header: {
                Text("Export")
            } footer: {
                Text("The encrypted backup holds everything: the server key, your devices and their keys, settings and the denied list. It is protected with your password (at least 8 characters). There is no way back in without it. The settings-only export holds no keys and is not encrypted.")
            }

            Section {
                Button("Restore from a backup file") { showImporter = true }
                    .accessibilityIdentifier("backup.import")
            } header: {
                Text("Restore")
            } footer: {
                Text("Restoring replaces the current setup and settings. Devices paired since the backup was made are lost. Denied keys stay denied: the lists are combined.")
            }

            if needsPassword {
                Section {
                    SecureField("Backup password", text: $importPassword)
                        .textContentType(.password)
                    Button("Unlock backup") { unlockImport() }
                        .disabled(importPassword.isEmpty)
                } header: {
                    Text("This backup is encrypted")
                }
            }
        }
        .navigationTitle("Backup and restore")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $showExporter, document: exportDocument,
                      contentType: .ferryBackup,
                      defaultFilename: exportEncrypted ? "Ferry-backup.ferrybackup" : "Ferry-settings.ferrybackup") { _ in }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.ferryBackup, .json, .data]) { result in
            if case .success(let url) = result { readImport(url) }
        }
        .alert("Restore this backup?", isPresented: Binding(get: { confirmRestore != nil },
                                                            set: { if !$0 { confirmRestore = nil } })) {
            Button("Cancel", role: .cancel) { confirmRestore = nil }
            Button("Restore", role: .destructive) {
                if let backup = confirmRestore {
                    do {
                        try model.restoreBackup(backup)
                        message = "Backup restored."
                    } catch {
                        message = (error as? BackupError)?.description ?? error.localizedDescription
                    }
                }
                confirmRestore = nil
            }
        } message: {
            if let backup = confirmRestore {
                Text("Made \(Format.dateTime(backup.createdAt)) by Ferry \(backup.appVersion), with \(backup.peers.count) device(s). The current setup is replaced.")
            }
        }
        .alert("Backup", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func prepareExport(encrypted: Bool) {
        do {
            let backup = model.makeBackup(includesKeys: encrypted)
            let json = try JSONEncoder().encode(backup)
            exportDocument = BackupDocument(data: encrypted ? try BackupCrypto.seal(json, password: password) : json)
            exportEncrypted = encrypted
            showExporter = true
        } catch {
            message = (error as? BackupError)?.description ?? error.localizedDescription
        }
    }

    private func readImport(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else {
            message = "That file couldn't be read."
            return
        }
        if BackupCrypto.isEncrypted(data) {
            pendingImport = data
            needsPassword = true
        } else {
            decodeImport(data)
        }
    }

    private func unlockImport() {
        guard let pendingImport else { return }
        do {
            let json = try BackupCrypto.open(pendingImport, password: importPassword)
            needsPassword = false
            self.pendingImport = nil
            decodeImport(json)
        } catch {
            message = (error as? BackupError)?.description ?? error.localizedDescription
        }
    }

    private func decodeImport(_ json: Data) {
        do {
            let backup = try JSONDecoder().decode(FerryBackup.self, from: json)
            _ = try backup.validated() // fail here, before the person confirms, not after
            confirmRestore = backup
        } catch let error as BackupError {
            message = error.description
        } catch {
            message = "That file isn't a Ferry backup."
        }
    }
}
