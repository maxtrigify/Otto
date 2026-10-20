import CoreGraphics
import Testing

@testable import OttoApp

@Suite("Motion tokens")
struct OttoMotionTests {
  @Test func exitsAreOneTierQuickerThanEntrances() {
    for tier in [OttoMotion.fast, OttoMotion.moderate, OttoMotion.slow] {
      #expect(tier.exitDuration < tier.duration)
    }
    #expect(OttoMotion.fast.duration < OttoMotion.moderate.duration)
    #expect(OttoMotion.moderate.duration < OttoMotion.slow.duration)
    // Only the largest tier keeps any bounce; the others land exactly.
    #expect(OttoMotion.fast.bounce == 0)
    #expect(OttoMotion.moderate.bounce == 0)
    #expect(OttoMotion.slow.bounce > 0)
  }

  @Test func reducedMotionDropsTravelButKeepsFades() {
    let reduced = OttoMotionResolver(reduceMotion: true)
    #expect(reduced.enter(.moderate) == nil)
    #expect(reduced.exit(.slow) == nil)
    #expect(reduced.presence(.fast, isPresented: true) == nil)
    #expect(reduced.fade == OttoMotion.fade)
    let full = OttoMotionResolver(reduceMotion: false)
    #expect(full.enter(.moderate) != nil)
    #expect(full.presence(.slow, isPresented: false) == OttoMotion.slow.exit)
  }

  @Test func cssTokensCarryEveryTier() {
    for token in [
      "--otto-motion-fast:80ms", "--otto-motion-fast-exit:60ms",
      "--otto-motion-moderate:160ms", "--otto-motion-moderate-exit:120ms",
      "--otto-motion-slow:240ms", "--otto-motion-slow-exit:160ms",
    ] {
      #expect(OttoMotion.cssTokens.contains(token))
    }
  }
}

@Suite("Fluid hover picking")
struct OttoFluidHoverPickerTests {
  private let rows: [OttoFluidHoverItem] = [
    OttoFluidHoverItem(id: "a", frame: CGRect(x: 0, y: 0, width: 100, height: 30), disabled: false),
    OttoFluidHoverItem(
      id: "b", frame: CGRect(x: 0, y: 34, width: 100, height: 30), disabled: false),
    OttoFluidHoverItem(id: "c", frame: CGRect(x: 0, y: 68, width: 100, height: 30), disabled: true),
    OttoFluidHoverItem(
      id: "d", frame: CGRect(x: 0, y: 102, width: 100, height: 30), disabled: false),
  ]

  @Test func aPointerInsideARowPicksThatRow() {
    #expect(
      OttoFluidHoverPicker.nearest(to: CGPoint(x: 10, y: 40), in: rows, axis: .vertical)
        == AnyHashable("b"))
  }

  @Test func aPointerInAGapPicksTheNearestRowSoTheHighlightNeverBlinks() {
    // y = 33 sits in the 4pt gap between a and b; b's centre (49) is nearer than a's (15).
    #expect(
      OttoFluidHoverPicker.nearest(to: CGPoint(x: 10, y: 33), in: rows, axis: .vertical)
        == AnyHashable("b"))
    #expect(
      OttoFluidHoverPicker.nearest(to: CGPoint(x: 10, y: 31), in: rows, axis: .vertical)
        == AnyHashable("a"))
  }

  @Test func disabledRowsArePassedOver() {
    // y = 90 is inside disabled c; the nearest enabled centre is d's (117), not b's (49).
    #expect(
      OttoFluidHoverPicker.nearest(to: CGPoint(x: 10, y: 90), in: rows, axis: .vertical)
        == AnyHashable("d"))
  }

  @Test func horizontalAndGridAxesMeasureAlongTheirOwnDirection() {
    let strip: [OttoFluidHoverItem] = [
      OttoFluidHoverItem(id: 0, frame: CGRect(x: 0, y: 0, width: 40, height: 20), disabled: false),
      OttoFluidHoverItem(id: 1, frame: CGRect(x: 50, y: 0, width: 40, height: 20), disabled: false),
    ]
    #expect(
      OttoFluidHoverPicker.nearest(to: CGPoint(x: 46, y: 60), in: strip, axis: .horizontal)
        == AnyHashable(1))
    #expect(
      OttoFluidHoverPicker.nearest(to: CGPoint(x: 44, y: 60), in: strip, axis: .horizontal)
        == AnyHashable(0))
    #expect(
      OttoFluidHoverPicker.nearest(to: CGPoint(x: 46, y: 60), in: strip, axis: .grid)
        == AnyHashable(1))
  }

  @Test func emptyOrFullyDisabledListsPickNothing() {
    #expect(OttoFluidHoverPicker.nearest(to: .zero, in: [], axis: .vertical) == nil)
    let disabled = rows.map { OttoFluidHoverItem(id: $0.id, frame: $0.frame, disabled: true) }
    #expect(OttoFluidHoverPicker.nearest(to: .zero, in: disabled, axis: .vertical) == nil)
  }
}

@Suite("Scroll thumb geometry")
struct OttoScrollThumbGeometryTests {
  @Test func thumbTracksContentProportionallyAndRoundTrips() {
    let geometry = OttoScrollThumbGeometry.thumb(
      track: 200, content: 800, container: 200, offset: 300)
    #expect(geometry?.length == 50)
    #expect(geometry?.position == 75)
    let offset = OttoScrollThumbGeometry.offset(
      forThumbPosition: 75, track: 200, content: 800, container: 200)
    #expect(offset == 300)
  }

  @Test func shortThumbsKeepAMinimumLengthAndNoOverflowMeansNoThumb() {
    let geometry = OttoScrollThumbGeometry.thumb(
      track: 200, content: 20000, container: 200, offset: 0)
    #expect(geometry?.length == OttoScrollThumbGeometry.minimumLength)
    #expect(
      OttoScrollThumbGeometry.thumb(track: 200, content: 100, container: 200, offset: 0) == nil)
  }
}
