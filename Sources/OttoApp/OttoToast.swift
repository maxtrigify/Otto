import SwiftUI

/// A short-lived, non-interactive acknowledgement for lightweight actions such as copying.
/// Each notice carries an identity so repeating the same action restarts the dismissal timer.
struct OttoToastNotice: Equatable, Identifiable {
  let id = UUID()
  let message: String
  var symbol = "checkmark"
}

extension View {
  func ottoToast(
    _ notice: Binding<OttoToastNotice?>,
    scale: Double = 1,
    bottomPadding: Double = 14
  ) -> some View {
    modifier(
      OttoToastModifier(
        notice: notice,
        scale: scale,
        bottomPadding: bottomPadding
      ))
  }
}

private struct OttoToastModifier: ViewModifier {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Binding var notice: OttoToastNotice?
  let scale: Double
  let bottomPadding: Double

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .bottom) {
        if let notice {
          HStack(spacing: 6 * scale) {
            Image(systemName: notice.symbol)
              .font(.system(size: max(7, 8 * scale), weight: .bold))
              .foregroundStyle(palette.signal)
            Text(notice.message)
              .font(.ottoMono(max(6.5, 7.5 * scale), weight: .bold))
              .foregroundStyle(palette.paper)
          }
          .padding(.horizontal, 11 * scale)
          .frame(minHeight: 27 * scale)
          .background(palette.raised.opacity(0.96), in: Capsule())
          .overlay(Capsule().stroke(palette.paper.opacity(0.12), lineWidth: 1))
          .shadow(color: .black.opacity(0.28), radius: 12 * scale, y: 5 * scale)
          .transition(reduceMotion ? .opacity : .ottoToast)
          .id(notice.id)
          .padding(.bottom, bottomPadding * scale)
          .accessibilityLabel(notice.message)
          .accessibilityAddTraits(.isStaticText)
        }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: notice?.id)
      .task(id: notice?.id) {
        guard let id = notice?.id else { return }
        try? await Task.sleep(for: .seconds(1.6))
        guard !Task.isCancelled, notice?.id == id else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
          notice = nil
        }
      }
  }
}

private struct OttoToastTransitionModifier: ViewModifier {
  let isHidden: Bool

  func body(content: Content) -> some View {
    content
      .opacity(isHidden ? 0 : 1)
      .scaleEffect(isHidden ? 0.96 : 1)
      .offset(y: isHidden ? 8 : 0)
      .blur(radius: isHidden ? 4 : 0)
  }
}

private struct OttoStatusSwapTransitionModifier: ViewModifier {
  let isHidden: Bool
  let verticalOffset: Double

  func body(content: Content) -> some View {
    content
      .opacity(isHidden ? 0 : 1)
      .offset(y: isHidden ? verticalOffset : 0)
      .blur(radius: isHidden ? 2.5 : 0)
  }
}

extension AnyTransition {
  static var ottoStatusSwap: AnyTransition {
    .asymmetric(
      insertion: .modifier(
        active: OttoStatusSwapTransitionModifier(isHidden: true, verticalOffset: 4),
        identity: OttoStatusSwapTransitionModifier(isHidden: false, verticalOffset: 0)
      ),
      removal: .modifier(
        active: OttoStatusSwapTransitionModifier(isHidden: true, verticalOffset: -4),
        identity: OttoStatusSwapTransitionModifier(isHidden: false, verticalOffset: 0)
      )
    )
  }

  fileprivate static var ottoToast: AnyTransition {
    .modifier(
      active: OttoToastTransitionModifier(isHidden: true),
      identity: OttoToastTransitionModifier(isHidden: false)
    )
  }
}

// MARK: - Status and undo toasts

/// A short status message with an icon well: success pops in, errors give a small shake.
/// Modelled on the devl.dev toast set (rewritten for SwiftUI).
struct OttoStatusToast: Equatable, Identifiable {
  enum Kind: Equatable { case success, error, info }
  let id = UUID()
  var kind: Kind
  var title: String
  var detail: String?
}

/// An inverted bar at the bottom with an Undo button and a draining countdown. The action
/// it undoes only becomes permanent when the countdown ends.
struct OttoUndoToast: Equatable, Identifiable {
  let id = UUID()
  var title: String
  var detail: String?
  var symbol = "trash"
  var seconds: Double = 6
}

extension View {
  func ottoStatusToast(_ toast: Binding<OttoStatusToast?>) -> some View {
    modifier(OttoStatusToastModifier(toast: toast))
  }

  func ottoUndoToast(
    _ toast: Binding<OttoUndoToast?>, onUndo: @escaping () -> Void,
    onExpire: @escaping () -> Void
  ) -> some View {
    modifier(OttoUndoToastModifier(toast: toast, onUndo: onUndo, onExpire: onExpire))
  }
}

private struct OttoStatusToastModifier: ViewModifier {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Binding var toast: OttoStatusToast?

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .topTrailing) {
        if let toast {
          card(toast)
            .padding(.top, 16).padding(.trailing, 18)
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            .id(toast.id)
        }
      }
      .animation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.2), value: toast?.id)
      .task(id: toast?.id) {
        guard let current = toast else { return }
        try? await Task.sleep(for: .seconds(current.kind == .error ? 6 : 3.2))
        guard !Task.isCancelled, toast?.id == current.id else { return }
        toast = nil
      }
  }

  private func card(_ toast: OttoStatusToast) -> some View {
    let tint: Color =
      switch toast.kind {
      case .success: palette.signal
      case .error: palette.red
      case .info: palette.cyan
      }
    let symbol =
      switch toast.kind {
      case .success: "checkmark"
      case .error: "exclamationmark"
      case .info: "info"
      }
    let pops = !reduceMotion && toast.kind != .error
    let shakes = !reduceMotion && toast.kind == .error
    return HStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(tint)
        .frame(width: 26, height: 26)
        .background(tint.opacity(0.16), in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(toast.title).font(.ottoDisplay(13).weight(.semibold))
        if let detail = toast.detail {
          Text(detail).font(.ottoDisplay(11.5)).foregroundStyle(palette.muted).lineLimit(2)
        }
      }
      Spacer(minLength: 4)
      Button {
        self.toast = nil
      } label: {
        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
          .foregroundStyle(palette.muted).frame(width: 20, height: 20)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss")
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    .frame(width: 320)
    .foregroundStyle(palette.paper)
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(
          toast.kind == .error ? palette.red.opacity(0.35) : palette.paper.opacity(0.10))
    )
    .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
    .shadow(color: .black.opacity(0.18), radius: 16, y: 10)
    .keyframeAnimator(initialValue: ToastMotion(), trigger: toast.id) { view, motion in
      view.scaleEffect(motion.scale).offset(x: motion.shake)
    } keyframes: { _ in
      // Success pops, errors shake; both tracks always exist so the builder stays linear.
      KeyframeTrack(\.scale) {
        CubicKeyframe(pops ? 1.025 : 1, duration: 0.12)
        CubicKeyframe(pops ? 0.99 : 1, duration: 0.1)
        CubicKeyframe(1, duration: 0.1)
      }
      KeyframeTrack(\.shake) {
        LinearKeyframe(shakes ? -3 : 0, duration: 0.05)
        LinearKeyframe(shakes ? 3 : 0, duration: 0.07)
        LinearKeyframe(shakes ? -2 : 0, duration: 0.07)
        LinearKeyframe(shakes ? 2 : 0, duration: 0.05)
        LinearKeyframe(0, duration: 0.04)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

private struct ToastMotion {
  var scale: Double = 1
  var shake: Double = 0
}

private struct OttoUndoToastModifier: ViewModifier {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Binding var toast: OttoUndoToast?
  let onUndo: () -> Void
  let onExpire: () -> Void
  @State private var started = Date.now

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .bottom) {
        if let toast {
          TimelineView(.animation(minimumInterval: 0.05)) { timeline in
            let left = max(0, toast.seconds - timeline.date.timeIntervalSince(started))
            bar(toast, left: left)
          }
          .padding(.bottom, 22)
          .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
          .id(toast.id)
        }
      }
      .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15), value: toast?.id)
      .task(id: toast?.id) {
        guard let current = toast else { return }
        started = .now
        try? await Task.sleep(for: .seconds(current.seconds))
        guard !Task.isCancelled, toast?.id == current.id else { return }
        toast = nil
        onExpire()
      }
  }

  private func bar(_ toast: OttoUndoToast, left: Double) -> some View {
    // Inverted colours, like devl.dev: the bar reads as a system moment, not page content.
    let ink = palette.paper
    let text = palette.ink
    return VStack(spacing: 8) {
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          Image(systemName: toast.symbol)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 26, height: 26)
            .background(text.opacity(0.15), in: Circle())
          VStack(alignment: .leading, spacing: 1) {
            Text(toast.title).font(.ottoDisplay(13).weight(.semibold))
            if let detail = toast.detail {
              Text(detail).font(.ottoDisplay(11.5)).opacity(0.7).lineLimit(1)
            }
          }
          Spacer(minLength: 8)
          Button("Undo") {
            self.toast = nil
            onUndo()
          }
          .buttonStyle(.plain)
          .font(.ottoDisplay(12).weight(.semibold))
          .padding(.horizontal, 10).padding(.vertical, 5)
          .background(text.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
          .keyboardShortcut("z", modifiers: .command)
          Button {
            self.toast = nil
            onExpire()
          } label: {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).opacity(0.6)
              .frame(width: 20, height: 20)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Dismiss and delete now")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        GeometryReader { proxy in
          Rectangle().fill(text.opacity(0.4))
            .frame(width: proxy.size.width * left / toast.seconds)
        }
        .frame(height: 2)
        .background(text.opacity(0.1))
      }
      .frame(width: 400)
      .foregroundStyle(text)
      .background(ink, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
      Text(left > 0 ? String(format: "%.1fS LEFT TO UNDO", left) : "DELETED")
        .font(.ottoMono(9.5, weight: .medium)).tracking(2.4)
        .foregroundStyle(palette.muted)
    }
  }
}
