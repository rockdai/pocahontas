import PocahontasKit
import SwiftUI

struct AccountSettingsView: View {
  @Bindable var library: ConnectionLibrary
  @Environment(\.dismiss) private var dismiss
  @State private var mode = "Sign In"
  @State private var email = ""
  @State private var password = ""
  @State private var confirmation = ""
  @State private var oldPassword = ""
  @State private var code = ""
  @State private var codeId: String?
  @State private var codeEmail: String?
  @State private var busy = false
  @State private var notice: String?
  @State private var resetConfirmation = false
  @State private var deleteConfirmation = false
  @State private var copyConfirmation = false
  @State private var archiveConfirmation = false
  @State private var archived: [LibraryRecord] = []
  private enum Field: Hashable { case email, password, confirmation, code, currentPassword }
  @FocusState private var focusedField: Field?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Label("Your connections, on every device", systemImage: "person.crop.circle")
            .font(.headline)
          Text("Your password unlocks your encrypted connection library on this device.")
            .font(.callout).foregroundStyle(.secondary)
          Text(library.syncStatus).font(.caption).accessibilityIdentifier("sync.status")
          if let notice { Text(notice).font(.callout).accessibilityIdentifier("account.notice") }
        }
        if library.isSignedIn { signedIn } else { signedOut }
        if let reason = library.state.recoveryReason {
          Section("Saved edits") {
            Text(reason)
            ForEach(Array(archived.enumerated()), id: \.offset) { _, record in
              Label(record.name.isEmpty ? "Deleted connection" : record.name,
                systemImage: record.deleted ? "trash" : "doc")
            }
            Button("Copy Saved Library to This Device") { archiveConfirmation = true }
              .disabled(busy || library.isAccountBusy)
            Text("Copies each preserved library to this device. This may include multiple versions of a connection. Nothing is uploaded automatically.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        Section("Privacy") {
          Text("Passwords and SSH keys stay on this device unless you choose to share them. Shared credentials are encrypted before upload. Server trust and terminal output stay on each device.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped).libraryTextInput().accessibilityIdentifier("account.form")
      .onSubmit { focusedField = nil }
      .navigationTitle("Account & Sync")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }.disabled(busy || library.isAccountBusy)
        }
      }
      .confirmationDialog("Reset password and clear cloud data?", isPresented: $resetConfirmation,
        titleVisibility: .visible) {
        Button("Clear Data and Reset Password", role: .destructive) { submit(reset: true) }
      } message: {
        Text("This permanently replaces all hosts, SSH passwords and private keys stored in this account’s cloud library with an empty library.")
      }
      .confirmationDialog("Delete this account?", isPresented: $deleteConfirmation, titleVisibility: .visible) {
        Button("Delete Account", role: .destructive) {
          run { try await library.deleteAccount(password: oldPassword); oldPassword = "" }
        }
      } message: { Text("Your cloud connection library will be deleted. This cannot be undone.") }
      .confirmationDialog("Copy local connections to this account?", isPresented: $copyConfirmation,
        titleVisibility: .visible) {
        Button("Copy Connections") { run { try library.copyLocalConnectionsToAccount() } }
      } message: { Text("New copies will be created. Passwords and keys stay on this device unless you choose to share them.") }
      .confirmationDialog("Copy the preserved library to local storage?", isPresented: $archiveConfirmation,
        titleVisibility: .visible) {
        Button("Copy to This Device") { run { try library.copyArchivedChangesToLocal(); archived = [] } }
      } message: { Text("This includes the preserved connections and identities. Deleted entries are not restored, and no data is uploaded.") }
      .libraryError(library)
    }
    .librarySheetSize().interactiveDismissDisabled(busy || library.isAccountBusy)
    .onAppear {
      email = library.accountEmail ?? ""
      do { archived = try library.archivedRecords() } catch { notice = error.localizedDescription }
    }
    .onChange(of: mode) { _, _ in focusedField = nil; clearForm() }
    .onChange(of: email) { _, _ in codeId = nil; codeEmail = nil; code = "" }
  }

  @ViewBuilder private var signedOut: some View {
    Section {
      Picker("Account", selection: $mode) {
        Text("Sign In").tag("Sign In")
        Text("Register").tag("Register")
        Text("Reset Password").tag("Reset Password")
      }.pickerStyle(.segmented).accessibilityIdentifier("account.mode")
      TextField("Email", text: $email).textContentType(.username).accessibilityIdentifier("account.email")
        .focused($focusedField, equals: .email)
      SecureField("Password", text: $password)
        .textContentType(mode == "Sign In" ? .password : .newPassword)
        .accessibilityIdentifier("account.password").focused($focusedField, equals: .password)
      if mode != "Sign In" {
        Text("Use at least 15 characters.").font(.caption).foregroundStyle(.secondary)
        SecureField("Confirm password", text: $confirmation).textContentType(.newPassword)
          .accessibilityIdentifier("account.confirm").focused($focusedField, equals: .confirmation)
        HStack {
          TextField("8-digit email code", text: $code).textContentType(.oneTimeCode)
            .accessibilityIdentifier("account.code")
            .focused($focusedField, equals: .code)
          Button(codeId == nil ? "Send Code" : "Resend") {
            run {
              let address = email
              codeId = try await library.requestCode(email: address, reset: mode == "Reset Password")
              codeEmail = address
              notice = "If this email can be used for this request, a code will arrive shortly. It expires in 5 minutes."
            }
          }.disabled(!library.serverConfigured || email.isEmpty || busy).accessibilityIdentifier("account.send-code")
        }
      }
      if mode == "Reset Password" {
        Text("Resetting your password clears the encrypted data saved in this account’s cloud library.")
          .foregroundStyle(AppAppearance.warning)
      }
      Button(mode) {
        if mode == "Sign In" {
          run { try await library.signIn(email: email, password: password); clearForm() }
        } else if mode == "Register" { submit(reset: false) }
        else { resetConfirmation = true }
      }.buttonStyle(.borderedProminent)
        .disabled(!canSubmit).accessibilityIdentifier("account.submit")
      if library.serverConfigured, let validationMessage {
        Text(validationMessage).font(.caption).foregroundStyle(AppAppearance.warning)
          .accessibilityIdentifier("account.validation")
      }
      if !library.serverConfigured { Text(AccountError.notConfigured.localizedDescription).font(.caption) }
      if busy || library.isAccountBusy { ProgressView() }
    }.disabled(busy || library.isAccountBusy)
  }

  @ViewBuilder private var signedIn: some View {
    Section("Account") {
      LabeledContent("Email", value: library.accountEmail ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Email").accessibilityValue(library.accountEmail ?? "")
        .accessibilityIdentifier("account.email-value")
      LabeledContent("Waiting to upload", value: String(library.pendingCount))
      LabeledContent("Conflicts", value: String(library.conflictCount))
      if let lastSync = library.lastSync { LabeledContent("Last sync") { Text(lastSync, style: .relative) } }
      Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
        run { await library.syncNow() }
      }.disabled(library.isSyncing)
      Button("Copy Local Connections to Account") { copyConfirmation = true }
      Button("Sign Out") { run { try library.signOut(); clearForm() } }
    }.disabled(busy || library.isAccountBusy)
    Section("Change password") {
      SecureField("Current password", text: $oldPassword).textContentType(.password)
        .accessibilityIdentifier("account.old-password").focused($focusedField, equals: .currentPassword)
      SecureField("New password (15+ characters)", text: $password).textContentType(.newPassword)
        .accessibilityIdentifier("account.new-password").focused($focusedField, equals: .password)
      SecureField("Confirm new password", text: $confirmation).textContentType(.newPassword)
        .accessibilityIdentifier("account.new-confirm").focused($focusedField, equals: .confirmation)
      Button("Change Password") {
        run {
          try await library.changePassword(oldPassword: oldPassword, newPassword: password)
          clearForm()
          notice = "Password changed. Other devices must sign in again."
        }
      }.disabled(oldPassword.isEmpty || password != confirmation || (try? AccountCrypto.validatePassword(password)) == nil)
      Text("Your encrypted library is preserved. Other devices will need the new password.").font(.caption)
    }.disabled(busy || library.isAccountBusy)
    Section {
      Button("Delete Account", role: .destructive) { deleteConfirmation = true }
        .disabled(oldPassword.isEmpty)
      Text("Enter your current password above to delete the account.").font(.caption)
    }.disabled(busy || library.isAccountBusy)
  }
  private var canSubmit: Bool {
    library.serverConfigured && !busy && !library.isAccountBusy && validationMessage == nil
  }
  private var normalizedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var validationMessage: String? {
    if email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter your email address." }
    if password.isEmpty { return "Enter your password." }
    if mode == "Sign In" { return nil }
    do { try AccountCrypto.validatePassword(password) } catch { return error.localizedDescription }
    if confirmation.isEmpty { return "Confirm your password." }
    if password != confirmation { return "Passwords do not match." }
    if codeId == nil || codeEmail != email { return "Select Send Code to get a verification code for this email." }
    if normalizedCode.utf8.count != 8 || !normalizedCode.utf8.allSatisfy({ (48...57).contains($0) }) {
      return "Enter the 8-digit code from your email."
    }
    return nil
  }
  private func submit(reset: Bool) {
    guard canSubmit, let codeId else { return }
    run {
      try await library.registerOrReset(email: email, password: password, codeId: codeId,
        code: normalizedCode, reset: reset, confirmDelete: reset)
      clearForm()
    }
  }
  private func clearForm() {
    password = ""; confirmation = ""; oldPassword = ""; code = ""; codeId = nil; codeEmail = nil
  }
  private func run(_ action: @escaping @MainActor () async throws -> Void) {
    focusedField = nil
    busy = true
    notice = nil
    Task {
      defer { busy = false }
      do { try await action() } catch { notice = error.localizedDescription }
    }
  }
}
