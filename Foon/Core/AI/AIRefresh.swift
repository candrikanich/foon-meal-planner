import Foundation
#if os(iOS)
import BackgroundTasks

/// A background refresh in which a capable iPhone or iPad claims one of the family's waiting AI jobs. iOS decides when, or
/// whether, it runs. The Mac claims only when Foon opens.
enum AIRefresh {
    /// In `BGTaskSchedulerPermittedIdentifiers` (project.yml).
    static let id = "com.andrikanich.foon.ai"
    /// Jobs wait up to 3 days, so an hourly look is plenty.
    static let interval: TimeInterval = 60 * 60
    /// iOS gives a refresh about 30 seconds, so the model gets less than that and the job is reported before the end. A run
    /// that's cut off anyway leaves its claim to lapse for another device.
    static let modelTimeout: Duration = .seconds(20)

    /// Only on a device that can run the model: anywhere else there'd be nothing to do.
    static func scheduleIfCapable(ai: AIService = .live, now: Date = .now) {
        guard ai.canRun else { return }
        let request = BGAppRefreshTaskRequest(identifier: id)
        request.earliestBeginDate = now.addingTimeInterval(interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func run(client: AIJobClient) async {
        var ai = AIService.live
        ai.timeout = modelTimeout
        _ = await AIJobRunner(client: client, ai: ai).drain(limit: 1)
        scheduleIfCapable(ai: ai)
    }
}
#endif
