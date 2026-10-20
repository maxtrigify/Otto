import Foundation

/// One slide for PowerPoint: a full-bleed background picture with native shapes on top.
public struct PPTXSlide: Sendable {
  public var background: Data
  public var shapes: [PPTXShape]
  public var notes: String
  public init(background: Data, shapes: [PPTXShape] = [], notes: String = "") {
    self.background = background
    self.shapes = shapes
    self.notes = notes
  }
}

/// Positions are in slide pixels (1280×720).
public enum PPTXShape: Sendable {
  case text(PPTXText)
  case box(
    x: Double, y: Double, w: Double, h: Double, fill: PPTXColor?, line: PPTXColor?, radius: Double)
  case picture(x: Double, y: Double, w: Double, h: Double, image: Data)
}

public struct PPTXColor: Equatable, Sendable {
  /// RRGGBB.
  public var hex: String
  /// 0...1.
  public var alpha: Double
  public init(hex: String, alpha: Double = 1) {
    self.hex = hex
    self.alpha = alpha
  }
}

public struct PPTXText: Sendable {
  public struct Run: Sendable {
    public var text: String
    public var bold: Bool
    public var italic: Bool
    public var color: PPTXColor
    public init(text: String, bold: Bool, italic: Bool, color: PPTXColor) {
      self.text = text
      self.bold = bold
      self.italic = italic
      self.color = color
    }
  }
  public var x, y, w, h: Double
  /// CSS pixels; written as points (×0.75).
  public var fontSize: Double
  public var font: String
  public var align: String
  public var lineHeight: Double
  public var letterSpacing: Double
  public var singleLine: Bool
  public var runs: [Run]
  public init(
    x: Double, y: Double, w: Double, h: Double, fontSize: Double, font: String, align: String,
    lineHeight: Double, letterSpacing: Double, singleLine: Bool, runs: [Run]
  ) {
    self.x = x
    self.y = y
    self.w = w
    self.h = h
    self.fontSize = fontSize
    self.font = font
    self.align = align
    self.lineHeight = lineHeight
    self.letterSpacing = letterSpacing
    self.singleLine = singleLine
    self.runs = runs
  }
}

/// A minimal, valid PowerPoint file. Slides are a background picture plus, when available,
/// native text boxes, shapes and pictures, so text stays editable in PowerPoint, Keynote and
/// Google Slides.
public enum PPTXWriter {
  private static let width = 12_192_000
  private static let height = 6_858_000
  private static let ns =
    #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#
  private static let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

  /// `images` are PNG or JPEG data, one per slide, shown full-bleed (the exact look).
  public static func data(images: [Data], notes: [String] = [], title: String = "Presentation")
    -> Data
  {
    data(
      slides: images.enumerated().map {
        PPTXSlide(background: $0.element, notes: $0.offset < notes.count ? notes[$0.offset] : "")
      }, title: title)
  }

  public static func data(slides: [PPTXSlide], title: String = "Presentation") -> Data {
    var entries: [(path: String, data: Data)] = []
    func add(_ path: String, _ text: String) { entries.append((path, Data(text.utf8))) }
    let count = slides.count

    add(
      "[Content_Types].xml",
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
      <Default Extension="xml" ContentType="application/xml"/>\
      <Default Extension="png" ContentType="image/png"/>\
      <Default Extension="jpeg" ContentType="image/jpeg"/>\
      <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>\
      <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>\
      <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>\
      <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\
      <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
      <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\
      \((0..<count).map { #"<Override PartName="/ppt/slides/slide\#($0 + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"# }.joined())\
      </Types>
      """)
    add(
      "_rels/.rels",
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
      <Relationship Id="rId1" Type="\(rel)/officeDocument" Target="ppt/presentation.xml"/>\
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
      <Relationship Id="rId3" Type="\(rel)/extended-properties" Target="docProps/app.xml"/>\
      </Relationships>
      """)
    add(
      "docProps/core.xml",
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>\(escape(title))</dc:title><dc:creator>Otto</dc:creator></cp:coreProperties>
      """)
    add(
      "docProps/app.xml",
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Otto</Application><Slides>\(count)</Slides></Properties>
      """)
    add(
      "ppt/presentation.xml",
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <p:presentation \(ns) saveSubsetFonts="1">\
      <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
      <p:sldIdLst>\((0..<count).map { #"<p:sldId id="\#(256 + $0)" r:id="rId\#(3 + $0)"/>"# }.joined())</p:sldIdLst>\
      <p:sldSz cx="\(width)" cy="\(height)"/><p:notesSz cx="6858000" cy="9144000"/>\
      </p:presentation>
      """)
    add(
      "ppt/_rels/presentation.xml.rels",
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
      <Relationship Id="rId1" Type="\(rel)/slideMaster" Target="slideMasters/slideMaster1.xml"/>\
      <Relationship Id="rId2" Type="\(rel)/theme" Target="theme/theme1.xml"/>\
      \((0..<count).map { #"<Relationship Id="rId\#(3 + $0)" Type="\#(rel)/slide" Target="slides/slide\#($0 + 1).xml"/>"# }.joined())\
      </Relationships>
      """)
    let emptyTree =
      #"<p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree>"#
    add(
      "ppt/slideMasters/slideMaster1.xml",
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <p:sldMaster \(ns)><p:cSld>\(emptyTree)</p:cSld>\
      <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
      <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>
      """)
    add(
      "ppt/slideMasters/_rels/slideMaster1.xml.rels",
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
      <Relationship Id="rId1" Type="\(rel)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
      <Relationship Id="rId2" Type="\(rel)/theme" Target="../theme/theme1.xml"/>\
      </Relationships>
      """)
    add(
      "ppt/slideLayouts/slideLayout1.xml",
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <p:sldLayout \(ns) type="blank" preserve="1"><p:cSld name="Blank">\(emptyTree)</p:cSld>\
      <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
      """)
    add(
      "ppt/slideLayouts/_rels/slideLayout1.xml.rels",
      """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
      <Relationship Id="rId1" Type="\(rel)/slideMaster" Target="../slideMasters/slideMaster1.xml"/>\
      </Relationships>
      """)
    add("ppt/theme/theme1.xml", theme)
    var mediaCount = 0
    for (index, slide) in slides.enumerated() {
      let number = index + 1
      var relationships = [
        #"<Relationship Id="rId1" Type="\#(rel)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>"#
      ]
      func media(_ data: Data) -> String {
        mediaCount += 1
        let name = "image\(mediaCount).\(ext(data))"
        entries.append(("ppt/media/\(name)", data))
        let id = "rId\(relationships.count + 1)"
        relationships.append(
          #"<Relationship Id="\#(id)" Type="\#(rel)/image" Target="../media/\#(name)"/>"#)
        return id
      }
      var shapeID = 1
      func nextID() -> Int {
        shapeID += 1
        return shapeID
      }
      var tree = picture(
        id: nextID(), name: "Background", rId: media(slide.background), x: 0, y: 0, w: 1280,
        h: 720, descr: slide.notes)
      for shape in slide.shapes {
        switch shape {
        case .picture(let x, let y, let w, let h, let image):
          tree += picture(
            id: nextID(), name: "Picture", rId: media(image), x: x, y: y, w: w, h: h, descr: "")
        case .box(let x, let y, let w, let h, let fill, let line, let radius):
          tree += box(id: nextID(), x: x, y: y, w: w, h: h, fill: fill, line: line, radius: radius)
        case .text(let text):
          tree += textBox(id: nextID(), text)
        }
      }
      add(
        "ppt/slides/slide\(number).xml",
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld \(ns)><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
        \(tree)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
        """)
      add(
        "ppt/slides/_rels/slide\(number).xml.rels",
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \(relationships.joined())</Relationships>
        """)
    }
    return ZipArchive.make(entries: entries)
  }

  private static func emu(_ px: Double) -> Int { Int((px * 9525).rounded()) }

  private static func xfrm(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> String {
    #"<a:xfrm><a:off x="\#(emu(x))" y="\#(emu(y))"/><a:ext cx="\#(emu(max(1, w)))" cy="\#(emu(max(1, h)))"/></a:xfrm>"#
  }

  private static func fill(_ color: PPTXColor) -> String {
    let alpha =
      color.alpha < 0.999 ? #"<a:alpha val="\#(Int((color.alpha * 100_000).rounded()))"/>"# : ""
    return #"<a:solidFill><a:srgbClr val="\#(color.hex)">\#(alpha)</a:srgbClr></a:solidFill>"#
  }

  private static func picture(
    id: Int, name: String, rId: String, x: Double, y: Double, w: Double, h: Double, descr: String
  ) -> String {
    """
    <p:pic><p:nvPicPr><p:cNvPr id="\(id)" name="\(name) \(id)" descr="\(escape(descr))"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
    <p:blipFill><a:blip r:embed="\(rId)"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
    <p:spPr>\(xfrm(x, y, w, h))<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>
    """
  }

  private static func box(
    id: Int, x: Double, y: Double, w: Double, h: Double, fill fillColor: PPTXColor?,
    line: PPTXColor?, radius: Double
  ) -> String {
    let adjust = Int(min(50_000, max(0, radius / max(1, min(w, h)) * 100_000)))
    let fillXML = fillColor.map(fill) ?? "<a:noFill/>"
    let lineXML = line.map { #"<a:ln w="9525">\#(fill($0))</a:ln>"# } ?? "<a:ln><a:noFill/></a:ln>"
    return """
      <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="Shape \(id)"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>\
      <p:spPr>\(xfrm(x, y, w, h))<a:prstGeom prst="roundRect"><a:avLst><a:gd name="adj" fmla="val \(adjust)"/></a:avLst></a:prstGeom>\
      \(fillXML)\(lineXML)</p:spPr></p:sp>
      """
  }

  private static func textBox(id: Int, _ text: PPTXText) -> String {
    let size = Int((text.fontSize * 0.75 * 100).rounded())
    let spacing = Int((text.letterSpacing * 0.75 * 100).rounded())
    let lineSpacing = Int(max(80, min(250, text.lineHeight / max(1, text.fontSize) * 100)) * 1_000)
    let align = ["center": "ctr", "right": "r", "end": "r", "justify": "just"][text.align] ?? "l"
    // Split runs into paragraphs on line breaks.
    var paragraphs: [[PPTXText.Run]] = [[]]
    for run in text.runs {
      let parts = run.text.components(separatedBy: "\n")
      for (index, part) in parts.enumerated() {
        if index > 0 { paragraphs.append([]) }
        if !part.isEmpty {
          var piece = run
          piece.text = part
          paragraphs[paragraphs.count - 1].append(piece)
        }
      }
    }
    let body = paragraphs.map { runs -> String in
      let runXML = runs.map { run in
        let typeface = escape(text.font)
        return """
          <a:r><a:rPr lang="en-GB" sz="\(size)" b="\(run.bold ? 1 : 0)" i="\(run.italic ? 1 : 0)"\(spacing == 0 ? "" : " spc=\"\(spacing)\"") dirty="0">\
          \(fill(run.color))<a:latin typeface="\(typeface)" panose="020B0604020202020204" pitchFamily="34" charset="0"/><a:cs typeface="\(typeface)" pitchFamily="34" charset="0"/></a:rPr><a:t>\(escape(run.text))</a:t></a:r>
          """
      }.joined()
      return """
        <a:p><a:pPr algn="\(align)"><a:lnSpc><a:spcPct val="\(lineSpacing)"/></a:lnSpc></a:pPr>\(runXML)\
        <a:endParaRPr lang="en-GB" sz="\(size)" dirty="0"/></a:p>
        """
    }.joined()
    // A little extra width absorbs font metric differences between renderers.
    let extra = text.singleLine ? text.w * 0.08 + 12 : 4
    let x = align == "ctr" ? text.x - extra / 2 : align == "r" ? text.x - extra : text.x
    return """
      <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="Text \(id)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>\
      <p:spPr>\(xfrm(x, text.y, text.w + extra, text.h))<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>\
      <p:txBody><a:bodyPr wrap="\(text.singleLine ? "none" : "square")" lIns="0" tIns="0" rIns="0" bIns="0" anchor="\(text.singleLine ? "ctr" : "t")"><a:noAutofit/></a:bodyPr>\
      <a:lstStyle/>\(body)</p:txBody></p:sp>
      """
  }

  private static func ext(_ image: Data) -> String {
    image.starts(with: [0xFF, 0xD8]) ? "jpeg" : "png"
  }

  private static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "\n", with: " ")
  }

  private static let theme = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Otto"><a:themeElements>\
    <a:clrScheme name="Otto"><a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>\
    <a:dk2><a:srgbClr val="1F2937"/></a:dk2><a:lt2><a:srgbClr val="F3F4F6"/></a:lt2>\
    <a:accent1><a:srgbClr val="FF7A45"/></a:accent1><a:accent2><a:srgbClr val="FFB86B"/></a:accent2>\
    <a:accent3><a:srgbClr val="3EE6C4"/></a:accent3><a:accent4><a:srgbClr val="8B7BFF"/></a:accent4>\
    <a:accent5><a:srgbClr val="2F5BFF"/></a:accent5><a:accent6><a:srgbClr val="5FE39A"/></a:accent6>\
    <a:hlink><a:srgbClr val="2F5BFF"/></a:hlink><a:folHlink><a:srgbClr val="7C4DFF"/></a:folHlink></a:clrScheme>\
    <a:fontScheme name="Otto"><a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\
    <a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>\
    <a:fmtScheme name="Otto"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>\
    <a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>\
    <a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>\
    <a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>\
    <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle>\
    <a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>\
    <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme>\
    </a:themeElements></a:theme>
    """
}
