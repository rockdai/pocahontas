import Foundation

public struct SSHConnection: Sendable, Equatable {
  public let host: String
  public let port: Int
  public let username: String

  public init(host: String, port: Int, username: String) throws {
    let input = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let host =
      input.hasPrefix("[") && input.hasSuffix("]") ? String(input.dropFirst().dropLast()) : input
    let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
      (1...65535).contains(port), !username.isEmpty
    else {
      throw SSHSessionError.invalidConnection
    }
    self.host = host
    self.port = port
    self.username = username
  }

  public var hostIdentity: String { "[\(host.lowercased())]:\(port)" }
}

public enum SSHAuthentication: Sendable {
  case password(String)
  case ed25519(openSSH: String, passphrase: String)
}

public struct TerminalSize: Sendable, Equatable {
  public let columns: Int
  public let rows: Int

  public init(columns: Int, rows: Int) {
    self.columns = min(65535, max(1, columns))
    self.rows = min(65535, max(1, rows))
  }
}

public enum SSHSessionState: Sendable, Equatable {
  case connecting, ready, disconnected
  case failed(String)
}

public enum SSHSessionError: LocalizedError, Sendable {
  case invalidConnection, invalidPrivateKey, unsupportedPrivateKey, hostKeyRejected
  case hostKeyChanged(previous: String, presented: String)
  case startupRejected, authenticationRejected, timeout, bufferLimit, notReady

  public var errorDescription: String? {
    switch self {
    case .invalidConnection: return "Enter a host, a port between 1 and 65535, and a username."
    case .invalidPrivateKey:
      return "Unable to unlock the OpenSSH key. Check the key and passphrase."
    case .unsupportedPrivateKey: return "This build supports OpenSSH Ed25519 private keys."
    case .hostKeyRejected: return "The server key was not trusted."
    case .hostKeyChanged(let previous, let presented):
      return
        "Server identity changed. Connection blocked.\nTrusted: \(previous)\nReceived: \(presented)"
    case .startupRejected: return "The server rejected the terminal or shell request."
    case .authenticationRejected:
      return "The server rejected this authentication method or credential."
    case .timeout: return "The connection did not become ready in time."
    case .bufferLimit:
      return "The terminal could not keep up with the connection. Reconnect to continue."
    case .notReady: return "The terminal is not connected."
    }
  }
}
