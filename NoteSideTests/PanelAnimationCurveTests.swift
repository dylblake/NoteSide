import QuartzCore
import XCTest
@testable import NoteSide

/// Holds the edge panels' slide to the shape that reads as a natural
/// slide: leaves the edge at once, never lurches, never creeps. The panels
/// travel their whole width, so these are stricter than generic UI easing
/// advice — a strong ease-out (quint, the iOS sheet curve) fails them.
/// `PanelMotionUITests` checks the same limits on the real, running panel.
@MainActor
final class PanelAnimationCurveTests: XCTestCase {
    /// Progress (0…1) of `curve` at normalised time `t`.
    private func progress(_ curve: CAMediaTimingFunction, at t: Double) -> Double {
        var p1 = [Float](repeating: 0, count: 2), p2 = [Float](repeating: 0, count: 2)
        curve.getControlPoint(at: 1, values: &p1)
        curve.getControlPoint(at: 2, values: &p2)
        let (x1, y1, x2, y2) = (Double(p1[0]), Double(p1[1]), Double(p2[0]), Double(p2[1]))
        func bezier(_ u: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - u) * (1 - u) * u * a + 3 * (1 - u) * u * u * b + u * u * u
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<60 {
            let u = (lo + hi) / 2
            if bezier(u, x1, x2) < t { lo = u } else { hi = u }
        }
        return bezier((lo + hi) / 2, y1, y2)
    }

    /// Progress sampled at 240 steps across the duration.
    private var samples: [Double] {
        (0...240).map { progress(PanelAnimation.slideCurve, at: Double($0) / 240) }
    }

    func testSlideLeavesTheEdgeImmediately() {
        // No ease-in: the first 5% of the time covers at least 5% of the
        // distance, so the panel visibly moves on the first frame.
        XCTAssertGreaterThanOrEqual(progress(PanelAnimation.slideCurve, at: 0.05), 0.05)
    }

    func testSlideNeverLurches() {
        // Peak speed at most 2.5× the average: no frame jumps a big chunk
        // of the panel's width.
        let steps = zip(samples.dropFirst(), samples).map { $0 - $1 }
        let average = 1.0 / Double(steps.count)
        XCTAssertLessThanOrEqual(steps.max()! / average, 2.5)
    }

    func testSlideDoesNotCreep() {
        // 90% of the travel isn't done before 55% of the time — otherwise
        // most of the slide is spent inching the last few points.
        let firstIndexAt90 = samples.firstIndex { $0 >= 0.9 }!
        XCTAssertGreaterThanOrEqual(Double(firstIndexAt90) / 240, 0.55)
    }

    func testSlideDecelerates() {
        // Ease-out: speed never increases along the way.
        let steps = zip(samples.dropFirst(), samples).map { $0 - $1 }
        for (earlier, later) in zip(steps, steps.dropFirst()) {
            XCTAssertLessThanOrEqual(later, earlier + 1e-9)
        }
    }

    func testDurationsStayResponsive() {
        XCTAssert((0.2...0.35).contains(PanelAnimation.presentDuration))
        XCTAssert((0.15...0.3).contains(PanelAnimation.dismissDuration))
        XCTAssertLessThan(PanelAnimation.dismissDuration, PanelAnimation.presentDuration)
    }

    func testPartialSlidesScaleWithDistance() {
        XCTAssertEqual(PanelAnimation.duration(0.3, remaining: 640, of: 640), 0.3, accuracy: 1e-9)
        XCTAssertEqual(PanelAnimation.duration(0.3, remaining: 320, of: 640), 0.15, accuracy: 1e-9)
        XCTAssertEqual(PanelAnimation.duration(0.3, remaining: 10, of: 640), PanelAnimation.minimumRetargetDuration)
    }
}
