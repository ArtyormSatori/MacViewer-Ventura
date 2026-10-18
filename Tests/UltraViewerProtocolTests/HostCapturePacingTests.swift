import Foundation
import Testing
@testable import UltraViewerProtocol

struct HostCapturePacingTests {
    @Test("Pacing starts at the historical 250 ms")
    func startsAtLegacyCadence() {
        #expect(HostCapturePacing().milliseconds == 250)
    }

    @Test("Changed frames halve the delay down to the 50 ms floor")
    func changedFramesSpeedUp() {
        var pacing = HostCapturePacing()
        pacing.frameChanged(); #expect(pacing.milliseconds == 125)
        pacing.frameChanged(); #expect(pacing.milliseconds == 62)
        pacing.frameChanged(); #expect(pacing.milliseconds == 50)
        pacing.frameChanged(); #expect(pacing.milliseconds == 50)
    }

    @Test("Unchanged frames double the delay up to the 1000 ms ceiling")
    func unchangedFramesBackOff() {
        var pacing = HostCapturePacing()
        pacing.frameUnchanged(); #expect(pacing.milliseconds == 500)
        pacing.frameUnchanged(); #expect(pacing.milliseconds == 1000)
        pacing.frameUnchanged(); #expect(pacing.milliseconds == 1000)
    }

    @Test("An idle spell recovers to full speed within a few changed frames")
    func recoveryAfterIdle() {
        var pacing = HostCapturePacing()
        for _ in 0..<3 { pacing.frameUnchanged() }
        #expect(pacing.milliseconds == 1000)
        for _ in 0..<5 { pacing.frameChanged() }
        #expect(pacing.milliseconds == 50)
    }
}
