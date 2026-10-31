import Foundation
import Observation
import PocahontasKit
import Security

@MainActor @Observable final class LibraryServices {
  static let shared = LibraryServices()
  let library: ConnectionLibrary?
  let startupError: String?
  private var started = false
  private init() {
    do {
      let requested =
        Bundle.main.object(forInfoDictionaryKey: "PocahontasCloudEnabled") as? String == "YES"
      let group = Bundle.main.object(forInfoDictionaryKey: "PocahontasKeychainGroup") as? String
      var configured = requested && group?.contains("$(") == false
      #if targetEnvironment(simulator)
        configured = false
      #elseif os(macOS)
        if let task = SecTaskCreateFromSelf(nil) {
          let containers =
            SecTaskCopyValueForEntitlement(
              task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
            as? [String]
          configured = configured && containers?.contains(ConnectionLibrary.containerID) == true
        } else {
          configured = false
        }
      #endif
      #if os(macOS)
        let credentialsAvailable = configured
      #else
        let credentialsAvailable = true
      #endif
      library = try ConnectionLibrary(
        store: LibraryStore(),
        vault: KeychainCredentialVault(accessGroup: configured ? group : nil),
        cloudConfigured: configured,
        credentialStorageAvailable: credentialsAvailable)
      startupError = nil
    } catch {
      library = nil
      startupError =
        "The connection library could not be opened. Your existing data has not been replaced. \(error.localizedDescription)"
    }
  }
  func start() async {
    guard !started else { return }
    started = true
    await library?.checkAccount()
  }
}

extension TerminalController {
  func connectSaved(_ binding: ConnectionBinding, authentication: SSHAuthentication) async {
    let accountGeneration = LibraryServices.shared.library?.accountGeneration
    await connect(
      host: binding.host, port: String(binding.port), username: binding.username,
      authentication: authentication,
      stillAuthorized: { LibraryServices.shared.library?.accountGeneration == accountGeneration })
  }
}

struct PendingSavedConnection {
  let binding: ConnectionBinding
  let authentication: SSHAuthentication
  let generation: Int
}
