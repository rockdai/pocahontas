@preconcurrency import NIOCore
@preconcurrency import NIOEmbedded
@preconcurrency import NIOSSH
import XCTest

@testable import PocahontasKit

final class PTYHandlerTests: XCTestCase {
  func testReadyRequiresBothServerAcknowledgements() throws {
    let observations = Observations()
    let recorder = RequestRecorder()
    let handler = PTYHandler(
      size: .init(columns: 80, rows: 24),
      onReady: { observations.ready += 1 }, onOutput: { _, done in done() },
      onClose: { _ in observations.closed += 1 })
    let channel = EmbeddedChannel(handlers: [recorder, handler])
    defer { _ = try? channel.finish() }
    try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 22)).wait()
    XCTAssertEqual(recorder.requests, ["pty"])
    XCTAssertEqual(observations.ready, 0)
    handler.resize(.init(columns: 100, rows: 40), on: channel)
    channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
    XCTAssertEqual(recorder.requests, ["pty", "shell"])
    XCTAssertEqual(observations.ready, 0)
    channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
    XCTAssertEqual(recorder.requests, ["pty", "shell", "resize:100x40"])
    XCTAssertEqual(observations.ready, 1)
  }

  func testRejectedPTYNeverRequestsShell() throws {
    let observations = Observations()
    let recorder = RequestRecorder()
    let handler = PTYHandler(
      size: .init(columns: 80, rows: 24),
      onReady: { observations.ready += 1 }, onOutput: { _, done in done() },
      onClose: { _ in observations.closed += 1 })
    let channel = EmbeddedChannel(handlers: [recorder, handler])
    defer { _ = try? channel.finish() }
    try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 22)).wait()
    channel.pipeline.fireUserInboundEventTriggered(ChannelFailureEvent())
    XCTAssertEqual(recorder.requests, ["pty"])
    XCTAssertEqual(observations.ready, 0)
    XCTAssertEqual(observations.closed, 1)
  }
}

// These callbacks execute synchronously on EmbeddedEventLoop.
private final class Observations: @unchecked Sendable {
  var ready = 0
  var closed = 0
}

private final class RequestRecorder: ChannelOutboundHandler {
  typealias OutboundIn = SSHChannelData
  var requests: [String] = []
  func triggerUserOutboundEvent(
    context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?
  ) {
    switch event {
    case is SSHChannelRequestEvent.PseudoTerminalRequest: requests.append("pty")
    case is SSHChannelRequestEvent.ShellRequest: requests.append("shell")
    case let size as SSHChannelRequestEvent.WindowChangeRequest:
      requests.append("resize:\(size.terminalCharacterWidth)x\(size.terminalRowHeight)")
    default: break
    }
    promise?.succeed(())
  }
}
