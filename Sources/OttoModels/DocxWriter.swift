import Foundation

/// A Word document built for clean imports into Word and Google Docs: real Heading 1–3 and
/// Title styles (so outlines and tables of contents work), real bulleted and numbered lists,
/// and runs with bold, italic, underline, size and colour.
public struct DocxDocument: Equatable, Sendable {
  public enum Style: String, Sendable {
    case title, heading1, heading2, heading3, body, bullet, number
  }
  public enum Alignment: String, Sendable { case left, center, right, both }

  public struct Run: Equatable, Sendable {
    public var text: String
    public var bold = false
    public var italic = false
    public var underline = false
    /// Point size; nil uses the paragraph style's size.
    public var size: Double?
    /// RRGGBB without "#"; nil uses the style colour.
    public var color: String?
    public init(
      text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false,
      size: Double? = nil, color: String? = nil
    ) {
      self.text = text
      self.bold = bold
      self.italic = italic
      self.underline = underline
      self.size = size
      self.color = color
    }
  }

  public struct Paragraph: Equatable, Sendable {
    public var style: Style
    public var alignment: Alignment
    public var runs: [Run]
    public init(style: Style = .body, alignment: Alignment = .left, runs: [Run]) {
      self.style = style
      self.alignment = alignment
      self.runs = runs
    }
  }

  public var paragraphs: [Paragraph]
  public var title: String
  public init(paragraphs: [Paragraph], title: String = "") {
    self.paragraphs = paragraphs
    self.title = title
  }
}

public enum DocxWriter {
  public static func data(_ document: DocxDocument) -> Data {
    let ns =
      #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships""#
    let body = document.paragraphs.map(paragraph).joined()
    let entries: [(path: String, data: Data)] = [
      (
        "[Content_Types].xml",
        Data(
          """
          <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
          <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
          <Default Extension="xml" ContentType="application/xml"/>\
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
          <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
          <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>\
          <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
          </Types>
          """.utf8)
      ),
      (
        "_rels/.rels",
        Data(
          """
          <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
          <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
          </Relationships>
          """.utf8)
      ),
      (
        "docProps/core.xml",
        Data(
          """
          <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
          <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>\(escape(document.title))</dc:title><dc:creator>Otto</dc:creator></cp:coreProperties>
          """.utf8)
      ),
      (
        "word/_rels/document.xml.rels",
        Data(
          """
          <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
          <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>\
          </Relationships>
          """.utf8)
      ),
      (
        "word/document.xml",
        Data(
          """
          <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
          <w:document \(ns)><w:body>\(body)\
          <w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>\
          </w:body></w:document>
          """.utf8)
      ),
      ("word/styles.xml", Data(styles(ns).utf8)),
      ("word/numbering.xml", Data(numbering(ns).utf8)),
    ]
    return ZipArchive.make(entries: entries)
  }

  private static func paragraph(_ paragraph: DocxDocument.Paragraph) -> String {
    var properties = ""
    switch paragraph.style {
    case .title: properties += #"<w:pStyle w:val="Title"/>"#
    case .heading1: properties += #"<w:pStyle w:val="Heading1"/>"#
    case .heading2: properties += #"<w:pStyle w:val="Heading2"/>"#
    case .heading3: properties += #"<w:pStyle w:val="Heading3"/>"#
    case .bullet:
      properties +=
        #"<w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>"#
    case .number:
      properties +=
        #"<w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr>"#
    case .body: break
    }
    if paragraph.alignment != .left {
      properties += #"<w:jc w:val="\#(paragraph.alignment.rawValue)"/>"#
    }
    let runs = paragraph.runs.map(run).joined()
    return "<w:p>" + (properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>") + runs + "</w:p>"
  }

  private static func run(_ run: DocxDocument.Run) -> String {
    var properties = ""
    if run.bold { properties += "<w:b/>" }
    if run.italic { properties += "<w:i/>" }
    if run.underline { properties += #"<w:u w:val="single"/>"# }
    if let color = run.color { properties += #"<w:color w:val="\#(color)"/>"# }
    if let size = run.size { properties += #"<w:sz w:val="\#(Int((size * 2).rounded()))"/>"# }
    let parts = run.text.components(separatedBy: "\n")
    let text = parts.map { #"<w:t xml:space="preserve">\#(escape($0))</w:t>"# }
      .joined(separator: "<w:br/>")
    return "<w:r>" + (properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>") + text + "</w:r>"
  }

  private static func styles(_ ns: String) -> String {
    func heading(_ id: String, _ name: String, size: Int, before: Int, outline: Int?) -> String {
      let level = outline.map { #"<w:outlineLvl w:val="\#($0)"/>"# } ?? ""
      return """
        <w:style w:type="paragraph" w:styleId="\(id)"><w:name w:val="\(name)"/><w:basedOn w:val="Normal"/>\
        <w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="\(before)" w:after="120"/>\(level)</w:pPr>\
        <w:rPr><w:b/><w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/></w:rPr></w:style>
        """
    }
    return """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:styles \(ns)>\
      <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="Arial" w:cs="Arial"/>\
      <w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-GB"/></w:rPr></w:rPrDefault>\
      <w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
      <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
      \(heading("Title", "Title", size: 52, before: 0, outline: nil))\
      \(heading("Heading1", "heading 1", size: 40, before: 400, outline: 0))\
      \(heading("Heading2", "heading 2", size: 32, before: 360, outline: 1))\
      \(heading("Heading3", "heading 3", size: 28, before: 320, outline: 2))\
      <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/>\
      <w:qFormat/><w:pPr><w:spacing w:after="80"/><w:ind w:left="720"/><w:contextualSpacing/></w:pPr></w:style>\
      </w:styles>
      """
  }

  private static func numbering(_ ns: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:numbering \(ns)>\
    <w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>\
    <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/><w:lvlJc w:val="left"/>\
    <w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/></w:rPr></w:lvl></w:abstractNum>\
    <w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>\
    <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:lvlJc w:val="left"/>\
    <w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>\
    <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>\
    </w:numbering>
    """
  }

  private static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
      .filter { $0 == "\t" || $0.unicodeScalars.allSatisfy { $0.value >= 0x20 } }
  }
}

extension DocxDocument {
  /// The paragraph texts of a .docx whose document part is stored uncompressed (as Otto writes
  /// them). Formatting is dropped. Returns nil for compressed or unrecognised files.
  public static func plainParagraphs(fromDocx data: Data) -> [String]? {
    guard let part = ZipArchive.storedEntry(named: "word/document.xml", in: data) else {
      return nil
    }
    let xml = String(decoding: part, as: UTF8.self)
    guard xml.contains("<w:body") else { return nil }
    return xml.components(separatedBy: "</w:p>").dropLast().map { paragraph in
      var text = ""
      var rest = Substring(paragraph)
      while let open = rest.range(of: "<w:t") {
        guard let tagEnd = rest[open.upperBound...].firstIndex(of: ">") else { break }
        // Skip <w:tab/>, <w:tbl> and similar tags that merely share the prefix.
        let tagName = rest[open.upperBound..<tagEnd]
        guard tagName.isEmpty || tagName.first == " " else {
          rest = rest[tagEnd...]
          continue
        }
        guard rest[rest.index(before: tagEnd)] != "/",
          let close = rest[tagEnd...].range(of: "</w:t>")
        else {
          rest = rest[tagEnd...]
          continue
        }
        text += rest[rest.index(after: tagEnd)..<close.lowerBound]
        rest = rest[close.upperBound...]
      }
      return text.replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }
  }
}
