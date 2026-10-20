import OttoModels
import Testing

@testable import OttoApp

@Suite("Markdown theme invalidation")
struct MarkdownThemeTests {
  @Test("Historical messages become unequal when the palette changes")
  @MainActor
  func paletteParticipatesInEquality() {
    let text = "A historical agent response"
    let dark = MarkdownMessageView(
      text: text,
      scale: 1,
      palette: OttoPalette(theme: OttoThemeCatalog.nightspire)
    )
    let light = MarkdownMessageView(
      text: text,
      scale: 1,
      palette: OttoPalette(theme: OttoThemeCatalog.fieldNotes)
    )

    #expect(dark != light)
    #expect(dark == dark)
  }

  @Test("Inline links remain interactive inside selectable transcript rows")
  func linkInteractionPolicy() {
    #expect(MarkdownInlineLinkPolicy.containsLink("[Otto plan](Research/Muse%20Plan.md)"))
    #expect(MarkdownInlineLinkPolicy.containsLink("Read [Apple's guidance](https://apple.com)."))
    #expect(MarkdownInlineLinkPolicy.containsLink("[Local file](file:///tmp/report.md)"))
    #expect(!MarkdownInlineLinkPolicy.containsLink("Plain **selectable** prose"))
    #expect(!MarkdownInlineLinkPolicy.containsLink("`https://example.com` is code, not a link"))
  }
}
