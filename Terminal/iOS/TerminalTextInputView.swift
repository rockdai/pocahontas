// Modified from baxian-app-ios under Apache-2.0: explicit paste handling.
// See Licenses/baxian-app-ios-Apache-2.0.txt.
import UIKit

final class TerminalTextInputView: UITextView, UITextViewDelegate {
  var onCommit: ((String) -> Void)?
  var onDelete: (() -> Void)?
  var onPresses: ((Set<UIPress>) -> Set<UIPress>)?
  var onFocus: ((Bool) -> Void)?
  var onPaste: ((String) -> Void)?
  private var resetting = false

  init() {
    super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1), textContainer: nil)
    delegate = self
    backgroundColor = .clear
    textColor = .clear
    tintColor = .clear
    isScrollEnabled = false
    isAccessibilityElement = false
    autocorrectionType = .no
    inlinePredictionType = .no
    autocapitalizationType = .none
    smartQuotesType = .no
    smartDashesType = .no
    smartInsertDeleteType = .no
    spellCheckingType = .no
  }

  required init?(coder: NSCoder) { fatalError("not supported") }

  override func insertText(_ text: String) {
    super.insertText(text)
    commitIfReady()
  }

  override func paste(_ sender: Any?) {
    if let text = UIPasteboard.general.string { onPaste?(text) }
  }

  override func unmarkText() {
    super.unmarkText()
    commitIfReady()
  }

  override func deleteBackward() {
    if markedTextRange != nil || !text.isEmpty {
      super.deleteBackward()
    } else {
      onDelete?()
    }
  }

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    guard markedTextRange == nil else {
      super.pressesBegan(presses, with: event)
      return
    }
    let unhandled = onPresses?(presses) ?? presses
    if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
  }

  func textViewDidChange(_ textView: UITextView) { commitIfReady() }
  func textViewDidBeginEditing(_ textView: UITextView) { onFocus?(true) }
  func textViewDidEndEditing(_ textView: UITextView) {
    discardComposition()
    onFocus?(false)
  }

  func discardComposition() {
    resetting = true
    super.unmarkText()
    text = ""
    resetting = false
  }

  private func commitIfReady() {
    guard !resetting, markedTextRange == nil, let committed = text, !committed.isEmpty else {
      return
    }
    resetting = true
    text = ""
    resetting = false
    onCommit?(committed)
  }
}
