import Foundation
import Testing

@testable import OttoModels

@Suite("Home cards")
struct HomeCardTests {
  @Test("Numbers read from friendly formats")
  func numbers() {
    #expect(HomeCardRow.number(from: "12,480") == 12_480)
    #expect(HomeCardRow.number(from: "1.2k") == 1_200)
    #expect(HomeCardRow.number(from: "$3.4M") == 3_400_000)
    #expect(HomeCardRow.number(from: "85%") == 85)
    #expect(HomeCardRow.number(from: "11:00") == nil)
    #expect(HomeCardRow.number(from: nil) == nil)
  }

  @Test("Replacing rows keeps each label's history, so numbers show their change")
  func historyCarriesOver() {
    var card = HomeCard(title: "Socials", style: .metrics)
    card.apply(
      rows: [.init(label: "LinkedIn", value: "100"), .init(label: "Reddit", value: "40")],
      text: nil, mode: .replace, by: "Test")
    card.apply(
      rows: [.init(label: "linkedin", value: "120"), .init(label: "Substack", value: "9")],
      text: nil, mode: .replace, by: "Test")
    #expect(card.rows.map(\.label) == ["linkedin", "Substack"])
    #expect(card.rows[0].history == [100, 120])
    #expect(card.rows[0].delta == 20)
    #expect(card.rows[1].delta == nil)
  }

  @Test("Upsert adds and updates rows by label and can remove some")
  func upsert() {
    var card = HomeCard(title: "Socials", style: .metrics)
    card.apply(
      rows: [.init(label: "LinkedIn", value: "100"), .init(label: "Reddit", value: "40")],
      text: nil, mode: .replace, by: nil)
    card.apply(
      rows: [.init(label: "Substack", value: "9"), .init(label: "LinkedIn", value: "101")],
      text: nil, mode: .upsert, removing: ["reddit"], by: nil)
    #expect(card.rows.map(\.label) == ["LinkedIn", "Substack"])
    #expect(card.rows[0].delta == 1)
  }

  @Test("Similar titles are spotted, filler words ignored")
  func similarity() {
    #expect(HomeCard.titleSimilarity("Social followers", "My socials") == 1)
    #expect(HomeCard.titleSimilarity("Today's meetings", "Top meetings today") == 1)
    #expect(HomeCard.titleSimilarity("Social followers", "Today's meetings") == 0)
  }

  @Test("Automation answers parse from JSON, bullets or plain text")
  func parser() {
    let json = HomeCardOutputParser.parse(
      """
      Here you go:
      ```json
      {"rows":[{"label":"LinkedIn","value":12480,"detail":"followers"},{"label":" "}]}
      ```
      """)
    #expect(json?.rows?.map(\.label) == ["LinkedIn"])
    #expect(json?.rows?.first?.value == "12480")

    let bullets = HomeCardOutputParser.parse(
      "- Acme pricing call — 11:00\n- **Design review**: 14:30\n- Lunch")
    #expect(bullets?.rows?.map(\.label) == ["Acme pricing call", "Design review", "Lunch"])
    #expect(bullets?.rows?.map(\.value) == ["11:00", "14:30", nil])

    #expect(HomeCardOutputParser.parse("Quiet day ahead.")?.text == "Quiet day ahead.")
    #expect(HomeCardOutputParser.parse("[SILENT]") == nil)
  }
}
