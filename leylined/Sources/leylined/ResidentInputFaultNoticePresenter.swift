import Foundation
import LeylineModel

@MainActor
protocol ResidentInputFaultNoticeSurface: AnyObject {
    func show(message: String)
    func hide()
}

/// The same pure projection and reusable surface own live and hermetic notice
/// delivery. One replaceable dismissal job is the only presentation timer.
@MainActor
final class ResidentInputFaultNoticePresenter {
    typealias Scheduler = @MainActor (UInt64, DispatchWorkItem) -> Void
    private var state = ResidentInputFaultNoticeState()
    private var surface: (any ResidentInputFaultNoticeSurface)?
    private var dismissalJob: DispatchWorkItem?
    private var dismissalTimer: DispatchSourceTimer?
    private let makeSurface: @MainActor () -> any ResidentInputFaultNoticeSurface
    private let uptimeProvider: @Sendable () -> UInt64
    private let schedule: Scheduler?
    private var acceptedCount = 0

    init(makeSurface: @escaping @MainActor () -> any ResidentInputFaultNoticeSurface,
         uptimeProvider: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         schedule: Scheduler? = nil) {
        self.makeSurface = makeSurface
        self.uptimeProvider = uptimeProvider
        self.schedule = schedule
    }

    @discardableResult
    func receive(_ event: ResidentInputFaultRelease, currentInputEpoch: String,
                 currentInputGeneration: UInt64) -> Bool {
        guard state.receive(event, currentInputEpoch: currentInputEpoch,
            currentInputGeneration: currentInputGeneration, now: uptimeProvider()) else { return false }
        dismissalJob?.cancel()
        if surface == nil { surface = makeSurface() }
        surface?.show(message: event.reason.humanMessage)
        acceptedCount += 1
        let job = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state.dismiss(event, now: self.uptimeProvider()) else { return }
                self.surface?.hide()
                self.dismissalJob = nil
            }
        }
        dismissalJob = job
        if let schedule { schedule(state.dismissalUptimeNs, job) }
        else {
            if dismissalTimer == nil {
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.setEventHandler { [weak self] in
                    MainActor.assumeIsolated { self?.dismissalJob?.perform() }
                }
                dismissalTimer = timer
                timer.resume()
            }
            // Reschedule the same source instead of accumulating canceled
            // asyncAfter blocks. It fires once and has no recurring idle wake.
            dismissalTimer?.schedule(deadline: DispatchTime(uptimeNanoseconds: state.dismissalUptimeNs), repeating: .never)
        }
        return true
    }

    func stop() {
        dismissalJob?.cancel()
        dismissalJob = nil
        dismissalTimer?.cancel()
        dismissalTimer = nil
        state.clear()
        surface?.hide()
    }

    var health: JSONObject {
        ["visible": .bool(state.visibleEvent != nil), "surface_count": .int(surface == nil ? 0 : 1),
         "accepted_events": .int(Int64(acceptedCount)), "dismissal_jobs": .int(dismissalJob == nil ? 0 : 1),
         "dismissal_milliseconds": .int(Int64(ResidentInputFaultNoticeConstants.dismissalMilliseconds)),
         "recurring_poll_count": .int(0)]
    }
}
