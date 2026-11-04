import Foundation
import PocahontasKit
import XCTest

final class AccountStorageTests: XCTestCase {
  func testLocalCredentialAndSessionSurviveNewStoreInstances() throws {
    let vault = KeychainCredentialVault(accessGroup: nil)
    let reference = CredentialReference(ownerScope: UUID().uuidString.lowercased(), kind: .password, storage: .account)
    defer { try? vault.delete(reference) }
    try vault.insert("public test SSH password", reference: reference)
    XCTAssertEqual(try KeychainCredentialVault(accessGroup: nil).read(reference), "public test SSH password")
    try vault.insert("public test SSH password", reference: reference)
    XCTAssertThrowsError(try vault.insert("different public test value", reference: reference))

    let url = URL(string: "https://\(UUID().uuidString.lowercased()).example.test")!
    let sessionStore = KeychainAccountSessionStore(server: url)
    defer { try? sessionStore.clear() }
    let bytes = try JSONSerialization.data(withJSONObject: [
      "email": "fixture@example.test", "userId": reference.ownerScope, "token": "public-test-token",
      "expiresAt": "2026-12-01T00:00:00.000Z", "passwordUpdatedAt": "2026-11-01T00:00:00.000Z",
      "salt": Data(repeating: 1, count: 32).base64EncodedString(),
      "dataKey": Data(repeating: 2, count: 32).base64EncodedString(),
    ])
    let session = try JSONDecoder().decode(AccountSession.self, from: bytes)
    try sessionStore.save(session)
    XCTAssertEqual(try KeychainAccountSessionStore(server: url).read()?.dataKey, session.dataKey)
    try sessionStore.clear()
    XCTAssertNil(try sessionStore.read())
  }
}
