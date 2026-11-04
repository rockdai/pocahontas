import Foundation
import Observation
import PocahontasKit

@MainActor @Observable final class LibraryServices {
  static let shared = LibraryServices()
  let library: ConnectionLibrary?
  let startupError: String?
  private var started = false
  private init() {
    do {
      let configuredURL = Bundle.main.object(forInfoDictionaryKey: "PocahontasServerURL") as? String ?? ""
      let url = configuredURL.isEmpty || configuredURL.contains("$(") ? nil : URL(string: configuredURL)
      let api = try url.map { try AccountAPI(baseURL: $0) }
      library = try ConnectionLibrary(
        store: LibraryStore(),
        vault: KeychainCredentialVault(accessGroup: nil), api: api,
        sessionStore: url.map { KeychainAccountSessionStore(server: $0) })
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

struct PendingSavedConnection {
  let binding: ConnectionBinding
  let authentication: SSHAuthentication
  let generation: Int
}
