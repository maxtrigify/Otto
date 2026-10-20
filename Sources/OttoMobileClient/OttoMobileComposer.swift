#if os(iOS)
  import SwiftUI
  import UIKit

  /// A multiline draft whose keyboard Send action matches the visible send button.
  struct OttoMobileComposer: UIViewRepresentable {
    @Binding var text: String
    var label: String
    var send: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
      let view = UITextView()
      view.delegate = context.coordinator
      view.font = .preferredFont(forTextStyle: .body)
      view.adjustsFontForContentSizeCategory = true
      view.backgroundColor = .clear
      view.textColor = .label
      view.textContainerInset = .zero
      view.textContainer.lineFragmentPadding = 0
      view.returnKeyType = .send
      view.enablesReturnKeyAutomatically = true
      view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
      context.coordinator.parent = self
      view.accessibilityLabel = label
      if view.text != text { view.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize?
    {
      let width = proposal.width ?? 280
      let lineHeight = uiView.font?.lineHeight ?? 22
      let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
      return CGSize(width: width, height: min(max(measured.height, lineHeight), lineHeight * 5))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
      var parent: OttoMobileComposer
      init(_ parent: OttoMobileComposer) { self.parent = parent }

      func textViewDidChange(_ textView: UITextView) {
        parent.text = textView.text
        textView.invalidateIntrinsicContentSize()
      }

      func textView(
        _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
      ) -> Bool {
        guard text == "\n" else { return true }
        parent.send()
        return false
      }
    }
  }
#endif
