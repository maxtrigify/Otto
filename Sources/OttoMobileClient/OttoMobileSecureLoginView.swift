#if canImport(SwiftUI)
  import OttoRPCContracts
  import SwiftUI

  /// Values live only in this private sheet until one explicit submission; never in OttoMobileStore.
  struct OttoMobileSecureLoginView: View {
    let store: OttoMobileStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var output = SecureLoginOutput()
    @State private var selected: SecureLoginRequest?
    @State private var values: [String: String] = [:]
    @State private var busy = false
    @State private var message = ""
    var body: some View {
      NavigationStack {
        Form {
          Text(
            "Private input goes directly to your paired Mac and the displayed website. Never enter passwords in chat. Verify the exact website before entering anything."
          )
          if let selected {
            Section(selected.origin) {
              ForEach(output.elements) { element in
                if element.kind == "field" || element.kind == "secret" {
                  VStack(alignment: .leading) {
                    if element.kind == "secret" {
                      SecureField(element.label, text: binding(element.id)).privacySensitive()
                    } else {
                      TextField(element.label, text: binding(element.id)).privacySensitive()
                        .autocorrectionDisabled()
                    }

                  }
                } else {
                  Button(element.label) {
                    perform(
                      SecureLoginInput(
                        action: .click, requestID: selected.id, revision: output.revision,
                        elementID: element.id, fields: values))
                  }
                }
              }
              Button("Refresh sign-in form") {
                values = [:]
                perform(SecureLoginInput(action: .form, requestID: selected.id))
              }
              Button("I'm signed in — allow bot access") {
                values = [:]
                perform(SecureLoginInput(action: .finish, requestID: selected.id))
              }
              Button("Cancel sign-in", role: .cancel) {
                values = [:]
                perform(SecureLoginInput(action: .cancel, requestID: selected.id))
              }
            }
          } else {
            ForEach(output.requests) { request in
              Button(request.origin) {
                selected = request
                perform(SecureLoginInput(action: .form, requestID: request.id))
              }
            }
            if output.requests.isEmpty {
              Text(
                "No sign-in requests. Ask your bot to request private sign-in, or open Website Accounts on your Mac."
              )
            }
            Button("Refresh") { perform(SecureLoginInput(action: .list)) }
          }
          if !message.isEmpty { Text(message) }
        }
        .disabled(busy)
        .navigationTitle("Secure Sign-in")
        .toolbar {
          Button("Close") {
            values = [:]
            dismiss()
          }
        }
        .task { perform(SecureLoginInput(action: .list)) }
        .onDisappear { values = [:] }
        .onChange(of: scenePhase) { _, phase in if phase != .active { values = [:] } }
      }
      .privacySensitive()
    }
    private func binding(_ id: String) -> Binding<String> {
      Binding(get: { values[id] ?? "" }, set: { values[id] = $0 })
    }
    private func perform(_ input: SecureLoginInput) {
      busy = true
      values = [:]
      message = ""
      Task {
        defer { busy = false }
        do {
          output = try await store.secureLogin(input)
          values = [:]
          message = output.message
          if input.action == .finish || input.action == .cancel { selected = nil }
        } catch {
          values = [:]
          message =
            "Sign-in request unavailable. Refresh, check your paired connection, or sign in on your Mac. Nothing was retried."
        }
      }
    }
  }
#endif
