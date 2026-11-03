import Foundation

public struct RemoteVault: Codable, Sendable {
  public var userId: String
  public var passwordUpdatedAt: String
  public var updatedAt: String
  public var salt: String
  public var ciphertext: String
}
public struct AccountLogin: Decodable, Sendable {
  public var token: String
  public var expiresAt: String
  public var userId: String
  public var vault: RemoteVault
}
public struct AccountProfile: Decodable, Sendable {
  public var userId: String
  public var email: String
  public var passwordUpdatedAt: String
}
private struct Prelogin: Decodable { var kdfVersion: Int; var iterations: Int; var salt: String }
private struct CodeResponse: Decodable { var codeId: String }
private struct UpdateResponse: Decodable { var updatedAt: String }

private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

public struct AccountAPI: Sendable {
  public let baseURL: URL
  private let session: URLSession
  public init(baseURL: URL, session: URLSession? = nil) throws {
    guard baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
      baseURL.path.isEmpty || baseURL.path == "/" else { throw AccountError.insecureServer }
    let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(baseURL.host ?? "")
    guard baseURL.scheme == "https" || (baseURL.scheme == "http" && local) else {
      throw AccountError.insecureServer
    }
    self.baseURL = baseURL
    if let session { self.session = session } else {
      let config = URLSessionConfiguration.ephemeral
      config.urlCache = nil
      config.httpCookieStorage = nil
      config.timeoutIntervalForRequest = 20
      config.timeoutIntervalForResource = 30
      self.session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }
  }
  private func request(_ method: String, _ path: String, body: [String: String]? = nil,
    token: String? = nil, confirmDelete: Bool = false) async throws -> Data {
    var request = URLRequest(url: baseURL.appendingPathComponent(path))
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.cachePolicy = .reloadIgnoringLocalCacheData
    if let body {
      var object: [String: Any] = body
      if confirmDelete { object["confirmDelete"] = true }
      request.httpBody = try JSONSerialization.data(withJSONObject: object)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse, data.count <= 1_600_000 else {
      throw AccountError.invalidData
    }
    if response.statusCode == 401 { throw AccountError.signedOut }
    if response.statusCode == 409 { throw AccountError.conflict }
    guard (200...299).contains(response.statusCode) else {
      struct Failure: Decodable { struct Detail: Decodable { var message: String }; var error: Detail }
      let message = (try? JSONDecoder().decode(Failure.self, from: data).error.message)
        ?? "The account service could not complete this request. Try again."
      throw AccountError.response(response.statusCode, message)
    }
    return data
  }
  public func requestCode(email: String, reset: Bool) async throws -> String {
    let path = reset ? "password/reset/code" : "register/code"
    return try JSONDecoder().decode(CodeResponse.self,
      from: await request("POST", "v1/auth/\(path)", body: ["email": email])).codeId
  }
  public func salt(email: String) async throws -> Data {
    let result = try JSONDecoder().decode(Prelogin.self,
      from: await request("POST", "v1/auth/prelogin", body: ["email": email]))
    guard result.kdfVersion == 1, result.iterations == AccountCrypto.iterations else { throw AccountError.invalidData }
    let salt = try Data(base64URL: result.salt)
    guard salt.count == 32 else { throw AccountError.invalidData }
    return salt
  }
  public func login(email: String, loginSecret: Data) async throws -> AccountLogin {
    try JSONDecoder().decode(AccountLogin.self, from: await request("POST", "v1/auth/login",
      body: ["email": email, "loginSecret": loginSecret.base64URL]))
  }
  public func registerOrReset(codeId: String, code: String, keys: AccountKeys,
    ciphertext: Data, reset: Bool) async throws {
    _ = try await request("POST", "v1/auth/\(reset ? "password/reset" : "register")", body:
      ["codeId": codeId, "code": code, "salt": keys.salt.base64URL,
       "loginSecret": keys.loginSecret.base64URL, "ciphertext": ciphertext.base64URL], confirmDelete: reset)
  }
  public func profile(token: String) async throws -> AccountProfile {
    try JSONDecoder().decode(AccountProfile.self, from: await request("GET", "v1/me", token: token))
  }
  public func vault(token: String) async throws -> RemoteVault {
    try JSONDecoder().decode(RemoteVault.self, from: await request("GET", "v1/vault", token: token))
  }
  public func save(ciphertext: Data, expectedUpdatedAt: String, token: String) async throws -> String {
    try JSONDecoder().decode(UpdateResponse.self, from: await request("PUT", "v1/vault",
      body: ["ciphertext": ciphertext.base64URL, "expectedUpdatedAt": expectedUpdatedAt], token: token)).updatedAt
  }
  public func changePassword(oldSecret: Data, keys: AccountKeys, ciphertext: Data,
    expectedUpdatedAt: String, expectedPasswordUpdatedAt: String, token: String) async throws {
    _ = try await request("PUT", "v1/auth/password", body: ["oldLoginSecret": oldSecret.base64URL,
      "salt": keys.salt.base64URL, "newLoginSecret": keys.loginSecret.base64URL,
      "ciphertext": ciphertext.base64URL, "expectedUpdatedAt": expectedUpdatedAt,
      "expectedPasswordUpdatedAt": expectedPasswordUpdatedAt], token: token)
  }
  public func deleteAccount(loginSecret: Data, token: String) async throws {
    _ = try await request("DELETE", "v1/me", body: ["loginSecret": loginSecret.base64URL], token: token)
  }
}
