import XCTest

final class OttoMobileAppUITests: XCTestCase {
  @MainActor
  func testKeyboardSendDeliversMessage() throws {
    let app = makeApp()
    let message = "KEYBOARD_SEND_\(UUID().uuidString.prefix(8))"
    app.launch()
    XCTAssertTrue(app.buttons["Ada"].waitForExistence(timeout: 10))
    app.buttons["Ada"].tap()
    let composer = app.textViews["Message Ada"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText(message + "\n")
    let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Received ‘\(message)’")).firstMatch
    XCTAssertTrue(reply.waitForExistence(timeout: 15), "Keyboard Send must dispatch the message, not insert a newline")
    XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", message)).count, 1)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Keyboard send and streamed reply"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testNightglassOnboardingOffersScanAndManualPairing() throws {
    let app = XCUIApplication()
    app.launchEnvironment = ["OTTO_MOBILE_RESET_PAIRING": "1"]
    app.launch()
    XCTAssertTrue(app.buttons["Scan Otto pairing QR code"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["REVIEW CONNECTION"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Nightglass welcome"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.buttons["Have a pairing code?"].tap()
    XCTAssertTrue(app.buttons["REVIEW CONNECTION"].exists)
    XCTAssertFalse(app.buttons["REVIEW CONNECTION"].isEnabled)
  }

  @MainActor
  func testSendStreamsAndRelaunchesWithoutDuplicates() throws {
    let app = makeApp()
    let messageBody = "PHONE PHASE ZERO E2E \(UUID().uuidString.prefix(8))"
    let streamedReplyFragment = "Received ‘\(messageBody)’"
    app.launch()

    let thread = app.buttons["Ada"]
    XCTAssertTrue(thread.waitForExistence(timeout: 10), "Ada should appear from the local host")
    thread.tap()

    XCTAssertTrue(
      app.staticTexts["Can I keep this session going from my phone?"].waitForExistence(timeout: 5),
      "The canonical transcript should load before sending"
    )

    let composer = app.textViews["Message Ada"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5), "The reply composer should be reachable")
    composer.tap()
    composer.typeText(messageBody)
    app.buttons["Send message"].tap()

    let interrupt = app.buttons["Interrupt"]
    let interruptDeadline = Date().addingTimeInterval(3)
    while !interrupt.exists && Date() < interruptDeadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    XCTAssertTrue(
      interrupt.exists,
      "A foreground run should expose its exact interrupt control"
    )
    interrupt.tap()

    let streamedReply = app.staticTexts.containing(
      NSPredicate(format: "label CONTAINS %@", streamedReplyFragment)
    ).firstMatch
    XCTAssertTrue(streamedReply.waitForExistence(timeout: 10), "The host reply should stream live")

    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["Ada"].waitForExistence(timeout: 10))
    app.buttons["Ada"].tap()

    let recoveredReplies = app.staticTexts.containing(
      NSPredicate(format: "label CONTAINS %@", streamedReplyFragment)
    )
    XCTAssertTrue(recoveredReplies.firstMatch.waitForExistence(timeout: 10))
    XCTAssertEqual(
      recoveredReplies.count, 1,
      "Snapshot and cursor replay must recover the streamed reply exactly once"
    )

    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Otto Mobile recovered thread"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor
  func testTeamRoomOpensWithoutPrivateMessages() throws {
    let app = makeApp()
    app.launch()
    let team = app.buttons["Studio Launch Team"]
    XCTAssertTrue(team.waitForExistence(timeout: 10))
    team.tap()
    XCTAssertTrue(
      app.staticTexts["Shared team plan: review the launch together."].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["Can I keep this session going from my phone?"].exists)
    let composer = app.textViews["Message Studio Launch Team"]
    XCTAssertTrue(composer.exists)
    composer.tap()
    composer.typeText("Review this together")
    app.buttons["Send message"].tap()
    XCTAssertTrue(app.staticTexts["Review this together"].waitForExistence(timeout: 5))
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Otto Mobile shared team room"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor
  func testPairingCodeReviewsMacIdentityBeforeExchange() throws {
    let app = XCUIApplication()
    app.launchEnvironment = [
      "OTTO_MOBILE_PAIRING_QR": Self.pairingQR,
      "OTTO_MOBILE_RESET_PAIRING": "1",
    ]
    app.launch()

    let review = app.buttons["REVIEW CONNECTION"]
    XCTAssertTrue(review.waitForExistence(timeout: 10), "The pairing fallback should be reachable")
    review.tap()

    XCTAssertTrue(
      app.staticTexts["Studio Mac"].waitForExistence(timeout: 5),
      "The user must see and confirm the environment name before exchange"
    )
    XCTAssertTrue(
      app.buttons["PAIR THIS IPHONE"].waitForExistence(timeout: 5),
      "Credential exchange must remain a separate explicit action"
    )
    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "Fingerprint aaaaaaaaaaaa")
      )
      .firstMatch.waitForExistence(timeout: 5),
      "The confirmation must expose a short host fingerprint"
    )

    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Otto Mobile pairing identity review"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor
  func testManagedPairingCodeExplainsRemoteTrustBeforeExchange() throws {
    let app = XCUIApplication()
    app.launchEnvironment = [
      "OTTO_MOBILE_PAIRING_QR": Self.managedPairingQR,
      "OTTO_MOBILE_RESET_PAIRING": "1",
    ]
    app.launch()

    let review = app.buttons["REVIEW CONNECTION"]
    XCTAssertTrue(review.waitForExistence(timeout: 10))
    review.tap()

    XCTAssertTrue(app.staticTexts["CONFIRM REMOTE ACCESS"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["relay.muse.test"].exists)
    XCTAssertTrue(app.buttons["ENABLE REMOTE ACCESS"].exists)
    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "short-lived, scoped commands")
      ).firstMatch.exists,
      "The confirmation must explain what the control plane relays"
    )

    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Otto Mobile managed pairing trust review"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor
  func testLivePairingExchangesCredentialAndOpensHome() throws {
    guard let pairingQR = ProcessInfo.processInfo.environment["OTTO_MOBILE_LIVE_PAIRING_QR"],
      !pairingQR.isEmpty
    else { throw XCTSkip("The live pairing host was not requested") }

    let app = XCUIApplication()
    app.launchEnvironment = [
      "OTTO_MOBILE_PAIRING_QR": pairingQR,
      "OTTO_MOBILE_RESET_PAIRING": "1",
    ]
    app.launch()

    let review = app.buttons["REVIEW CONNECTION"]
    XCTAssertTrue(review.waitForExistence(timeout: 10))
    review.tap()
    let pair = app.buttons["PAIR THIS IPHONE"]
    XCTAssertTrue(pair.waitForExistence(timeout: 5))
    pair.tap()

    XCTAssertTrue(
      app.buttons["Ada"].waitForExistence(timeout: 15),
      "A successfully paired device should authenticate and load the host thread list"
    )
    XCTAssertTrue(app.staticTexts["Otto Mobile Demo Mac"].exists)

    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Otto Mobile paired home"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor
  func testLiveManagedPairingSendsAndRelaunchesFromKeychain() throws {
    guard
      let pairingQR = ProcessInfo.processInfo.environment[
        "OTTO_MOBILE_LIVE_MANAGED_PAIRING_QR"
      ], !pairingQR.isEmpty
    else { throw XCTSkip("The live managed pairing topology was not requested") }

    let app = XCUIApplication()
    app.launchEnvironment = [
      "OTTO_MOBILE_PAIRING_QR": pairingQR,
      "OTTO_MOBILE_RESET_PAIRING": "1",
    ]
    let messageBody = "MANAGED RELAY E2E \(UUID().uuidString.prefix(8))"
    let replyFragment = "Received ‘\(messageBody)’"
    app.launch()

    let review = app.buttons["REVIEW CONNECTION"]
    XCTAssertTrue(review.waitForExistence(timeout: 10))
    review.tap()
    let enable = app.buttons["ENABLE REMOTE ACCESS"]
    XCTAssertTrue(enable.waitForExistence(timeout: 5))
    enable.tap()

    let composer = try openAdaThread(in: app, timeout: 20)
    composer.tap()
    composer.typeText(messageBody)
    app.buttons["Send message"].tap()

    let streamedReply = app.staticTexts.containing(
      NSPredicate(format: "label CONTAINS %@", replyFragment)
    ).firstMatch
    XCTAssertTrue(
      streamedReply.waitForExistence(timeout: 15),
      "The canonical host reply should arrive through the managed relay"
    )

    app.terminate()
    app.launchEnvironment = [:]
    app.launch()
    let recoveredComposer = try openAdaThread(in: app, timeout: 15)
    let recoveredReplies = app.staticTexts.containing(
      NSPredicate(format: "label CONTAINS %@", replyFragment)
    )
    XCTAssertTrue(recoveredReplies.firstMatch.waitForExistence(timeout: 10))
    XCTAssertEqual(recoveredReplies.count, 1)

    let approvalMessage = "APPROVAL RELAY E2E \(UUID().uuidString.prefix(8))"
    recoveredComposer.tap()
    recoveredComposer.typeText(approvalMessage)
    app.buttons["Send message"].tap()
    XCTAssertTrue(
      app.staticTexts["APPROVAL NEEDED"].waitForExistence(timeout: 15),
      "The typed host approval should arrive through the managed relay"
    )
    XCTAssertTrue(
      app.staticTexts["Bash: publish the signed release tag from this Mac"].exists,
      "The phone must show the exact action rather than a generic confirmation"
    )
    let approveOnce = app.buttons["Approve once"]
    XCTAssertTrue(approveOnce.waitForExistence(timeout: 5))
    approveOnce.tap()
    XCTAssertTrue(
      app.staticTexts[
        "Approved once on iPhone. The exact pending action was resolved on this Mac; replay is rejected."
      ]
      .waitForExistence(timeout: 15),
      "Approving on iPhone should unblock the exact pending host action"
    )

    app.buttons["Attach a file"].tap()
    let newNote = app.buttons["New Text Note"]
    XCTAssertTrue(newNote.waitForExistence(timeout: 5))
    newNote.tap()
    let noteText = app.textViews["Attachment note text"]
    XCTAssertTrue(noteText.waitForExistence(timeout: 5))
    noteText.tap()
    noteText.typeText("Managed attachment E2E \(UUID().uuidString.prefix(8))")
    let attachNote = app.buttons["Attach Note"]
    XCTAssertTrue(attachNote.isEnabled)
    attachNote.tap()
    XCTAssertTrue(
      app.staticTexts["Field note.txt"].waitForExistence(timeout: 15),
      "The verified attachment should appear on the live thread"
    )
    let download = app.buttons["Download Field note.txt"]
    XCTAssertTrue(download.waitForExistence(timeout: 5))
    download.tap()
    XCTAssertTrue(
      app.staticTexts["Downloaded Field note.txt"].waitForExistence(timeout: 15),
      "The same attachment should download through the managed relay"
    )
    XCTAssertTrue(
      app.buttons["Share Field note.txt"].waitForExistence(timeout: 5),
      "A downloaded attachment should be available to the iPhone share sheet"
    )

    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Otto Mobile managed attachment round trip"
    screenshot.lifetime = .keepAlways
    add(screenshot)

    let back = app.navigationBars.buttons.firstMatch
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    back.tap()
    let macHealth = app.buttons["Mac health and diagnostics"]
    XCTAssertTrue(
      macHealth.waitForExistence(timeout: 10),
      "A capable Mac should expose its privacy-safe health surface"
    )
    macHealth.tap()
    XCTAssertTrue(
      app.staticTexts["RECOVERED AFTER AN UNCLEAN EXIT"].waitForExistence(timeout: 10),
      "The real crash marker should survive the managed relay"
    )
    XCTAssertTrue(app.staticTexts["Tool · canvas.list"].exists)
    let prepareReport = app.buttons["Prepare aggregate report"]
    XCTAssertTrue(prepareReport.waitForExistence(timeout: 5))
    XCTAssertFalse(prepareReport.isEnabled, "Support export must be disabled before consent")
    let consent = app.switches["diagnostics.consent"]
    XCTAssertTrue(consent.waitForExistence(timeout: 5))
    consent.tap()
    XCTAssertTrue(prepareReport.isEnabled)
    prepareReport.tap()
    XCTAssertTrue(
      app.buttons["Share support report"].waitForExistence(timeout: 10),
      "Consent should prepare an aggregate-only report for the native share sheet"
    )
    let diagnosticsScreenshot = XCTAttachment(screenshot: app.screenshot())
    diagnosticsScreenshot.name = "Otto Mobile privacy-safe Mac health"
    diagnosticsScreenshot.lifetime = .keepAlways
    add(diagnosticsScreenshot)
  }

  @MainActor
  func testLiveManagedPairingExplainsExpiredSubscription() throws {
    guard
      let pairingQR = ProcessInfo.processInfo.environment[
        "OTTO_MOBILE_LIVE_MANAGED_PAIRING_QR"
      ], !pairingQR.isEmpty
    else { throw XCTSkip("The expired managed pairing topology was not requested") }

    let app = XCUIApplication()
    app.launchEnvironment = [
      "OTTO_MOBILE_PAIRING_QR": pairingQR,
      "OTTO_MOBILE_RESET_PAIRING": "1",
    ]
    app.launch()
    let review = app.buttons["REVIEW CONNECTION"]
    XCTAssertTrue(review.waitForExistence(timeout: 10))
    review.tap()
    let enable = app.buttons["ENABLE REMOTE ACCESS"]
    XCTAssertTrue(enable.waitForExistence(timeout: 5))
    enable.tap()

    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(
          format: "label CONTAINS %@",
          "Otto Remote needs an active subscription"
        )
      ).firstMatch.waitForExistence(timeout: 10),
      "Expired hosted access should explain the paid boundary rather than show an HTTP code"
    )
    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(
          format: "label CONTAINS %@",
          "Local and Tailscale pairing remain available"
        )
      ).firstMatch.exists)
    XCTAssertFalse(app.buttons["Ada"].exists, "A denied exchange must not open or persist the host")

    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Otto Remote subscription required"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor
  func testBotRosterStartsInactiveBotAndOpensCanonicalThread() throws {
    let app = makeApp()
    app.launch()

    XCTAssertTrue(app.buttons["Ada"].waitForExistence(timeout: 10))
    XCTAssertTrue(
      app.staticTexts["Studio Launch Team"].waitForExistence(timeout: 5),
      "Saved teams should be visible alongside the bot roster"
    )
    let rosterScreenshot = XCTAttachment(screenshot: app.screenshot())
    rosterScreenshot.name = "Otto Mobile bots and teams roster"
    rosterScreenshot.lifetime = .keepAlways
    add(rosterScreenshot)

    let startNova = app.buttons["Start Nova"]
    XCTAssertTrue(startNova.waitForExistence(timeout: 5))
    startNova.tap()

    XCTAssertTrue(
      app.staticTexts["Nova"].waitForExistence(timeout: 10),
      "Starting an inactive bot should open its canonical thread"
    )
    XCTAssertTrue(app.staticTexts["RUNS ON · THIS MAC"].exists)
    let threadScreenshot = XCTAttachment(screenshot: app.screenshot())
    threadScreenshot.name = "Otto Mobile newly started bot thread"
    threadScreenshot.lifetime = .keepAlways
    add(threadScreenshot)
  }

  @MainActor
  func testColdRelaunchUsesCachedHomeAndThreadWhenHostIsOffline() throws {
    let online = makeApp()
    online.launch()
    XCTAssertTrue(online.buttons["Ada"].waitForExistence(timeout: 10))
    online.buttons["Ada"].tap()
    XCTAssertTrue(
      online.staticTexts["Can I keep this session going from my phone?"]
        .waitForExistence(timeout: 5)
    )
    online.terminate()

    let offline = makeApp(hostURL: "http://127.0.0.1:65534/")
    offline.launch()
    XCTAssertTrue(
      offline.buttons["Ada"].waitForExistence(timeout: 10),
      "The cached home should render before an unavailable host responds"
    )
    XCTAssertTrue(offline.staticTexts["OFFLINE"].waitForExistence(timeout: 10))
    offline.buttons["Ada"].tap()
    XCTAssertTrue(
      offline.staticTexts["Can I keep this session going from my phone?"]
        .waitForExistence(timeout: 5),
      "The cached canonical transcript should remain readable offline"
    )
    XCTAssertTrue(offline.staticTexts["OFFLINE"].exists)

    let screenshot = XCTAttachment(screenshot: offline.screenshot())
    screenshot.name = "Otto Mobile cached thread offline"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor
  func testBackgroundCompletionPostsNativeNotification() throws {
    let app = makeApp()
    app.launch()
    let turnOn = app.buttons["Turn on notifications"]
    XCTAssertTrue(turnOn.waitForExistence(timeout: 10))
    turnOn.tap()

    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let allow = springboard.buttons["Allow"]
    XCTAssertTrue(
      allow.waitForExistence(timeout: 5), "iOS should present its native permission sheet")
    allow.tap()
    XCTAssertTrue(
      turnOn.waitForNonExistence(timeout: 5),
      "The opt-in card should disappear after authorization"
    )

    let ada = app.buttons["Ada"]
    XCTAssertTrue(ada.waitForExistence(timeout: 5))
    ada.tap()
    let composer = app.textViews["Message Ada"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText("Background notification check (UUID().uuidString.prefix(8))")
    app.buttons["Send message"].tap()
    XCTAssertTrue(app.buttons["Interrupt"].waitForExistence(timeout: 5))

    XCUIDevice.shared.press(.home)
    let completion = springboard.staticTexts["Ada finished"]
    XCTAssertTrue(
      completion.waitForExistence(timeout: 10),
      "A streamed run completion should become a native notification while backgrounded"
    )
    let screenshot = XCTAttachment(screenshot: springboard.screenshot())
    screenshot.name = "Otto Mobile background completion notification"
    screenshot.lifetime = .keepAlways
    add(screenshot)

    completion.tap()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    XCTAssertTrue(
      app.textViews["Message Ada"].waitForExistence(timeout: 5),
      "Tapping the completion notification should deep-link to its canonical thread"
    )
  }

  @MainActor
  private func makeApp(hostURL overrideHostURL: String? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    let hostURL =
      overrideHostURL ?? ProcessInfo.processInfo.environment["OTTO_MOBILE_UI_HOST_URL"]
      ?? "http://127.0.0.1:7338/"
    app.launchEnvironment = [
      "OTTO_MOBILE_DEMO_TOKEN": "otto-mobile-demo-token-2026-local-only",
      "OTTO_MOBILE_DEMO_HOST_URL": hostURL,
      "OTTO_MOBILE_DEMO_DEVICE_ID": "D9212942-8C77-4E2A-BF27-1A36DA8A5134",
    ]
    return app
  }

  @MainActor
  private func openAdaThread(
    in app: XCUIApplication,
    timeout: TimeInterval
  ) throws -> XCUIElement {
    let composer = app.textViews["Message Ada"]
    let ada = app.buttons["Ada"]
    let deadline = Date().addingTimeInterval(timeout)
    while !composer.exists && !ada.exists && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    if !composer.exists, ada.exists {
      ada.tap()
    }
    guard composer.waitForExistence(timeout: 5) else {
      XCTFail("Managed pairing should open or expose the connected Ada thread")
      throw NSError(domain: "OttoMobileAppUITests", code: 1)
    }
    return composer
  }

  // Fixtures keep the pre-rename muse:// scheme on purpose: printed codes still in circulation
  // must keep pairing with the renamed app.
  private static let pairingQR =
    "muse://pair?payload=eyJiYXNlVVJMIjoiaHR0cHM6Ly9zdHVkaW8tbWFjLmV4YW1wbGUudGVzdC8iLCJjb2RlIjoiMjA0ODEzIiwiZW52aXJvbm1lbnRJRCI6IjExMTExMTExLTIyMjItMzMzMy00NDQ0LTU1NTU1NTU1NTU1NSIsImVudmlyb25tZW50TmFtZSI6IlN0dWRpbyBNYWMiLCJleHBpcmVzQXQiOjE5MDAwMDAwMDAwMDAsImZpbmdlcnByaW50IjoiYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYSIsIm9mZmVySUQiOiJhYWFhYWFhYS1iYmJiLWNjY2MtZGRkZC1lZWVlZWVlZWVlZWUiLCJwcm90b2NvbFZlcnNpb24iOjEsInNjb3BlcyI6WyJlbnZpcm9ubWVudDpyZWFkIiwidGhyZWFkOnJlYWQiLCJtZXNzYWdlOndyaXRlIiwicnVuOmNvbnRyb2wiXX0"

  private static var managedPairingQR: String {
    let json =
      #"{"controlPlaneURL":"https://relay.muse.test/","expiresAt":"2035-01-01T12:00:00Z","offerID":"11111111-2222-3333-4444-555555555555","protocolVersion":1,"secret":"ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss"}"#
    let payload = Data(json.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "muse://remote?payload=\(payload)"
  }
}
