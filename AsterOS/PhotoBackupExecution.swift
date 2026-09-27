import UIKit
import BackgroundTasks

/// A delayed UIKit expiration must not cancel the continued-processing owner.
struct PhotoBackupBackgroundOwnership {
    enum Owner { case temporary, continued, finished }
    private(set) var owner: Owner = .temporary
    mutating func takeOver() -> Bool {
        guard owner != .finished else { return false }
        owner = .continued
        return true
    }
    mutating func expire(_ source: Owner) -> Bool {
        guard owner == source, owner != .finished else { return false }
        owner = .finished
        return true
    }
    mutating func finish() { owner = .finished }
}

/// One lease per explicit backup run. Never schedules unattended future backups.
@MainActor final class PhotoBackupExecution {
    private let identifier = (Bundle.main.bundleIdentifier ?? "com.asterlinelabs.asteros") + ".photo-backup." + UUID().uuidString
    private var lease: UIBackgroundTaskIdentifier = .invalid
    private var continued: BGTask?
    private var active = true
    private var ownership = PhotoBackupBackgroundOwnership()
    private var stop: ((String) -> Void)?
    private var report: ((String) -> Void)?
    private var lastProgress: Int64 = 0
    private var lastSubtitle = ""
    var allowsBackground: Bool { active && (continued != nil || lease != .invalid) }

    init(stop: @escaping (String) -> Void, report: @escaping (String) -> Void) {
        self.stop = stop; self.report = report
        lease = UIApplication.shared.beginBackgroundTask(withName: "Photo backup") { [weak self] in
            Task { @MainActor in self?.expire(.temporary) }
        }
        if #available(iOS 26.0, *) {
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
                Task { @MainActor in
                    guard let self, self.active, let task = task as? BGContinuedProcessingTask else {
                        task.setTaskCompleted(success: false); return
                    }
                    guard self.ownership.takeOver() else { task.setTaskCompleted(success: false); return }
                    self.continued = task
                    task.progress.totalUnitCount = 1_000_000_000
                    task.progress.completedUnitCount = self.lastProgress
                    task.expirationHandler = { [weak self] in Task { @MainActor in self?.expire(.continued) } }
                    self.endLease()
                    self.report?("Background backup enabled · iOS can pause it if resources are needed.")
                }
            }
            if registered {
                let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Photo backup", subtitle: "Preparing your backup")
                request.strategy = .fail
                do { try BGTaskScheduler.shared.submit(request) }
                catch { report("Background time is limited right now. Backup continues while AsterOS is open.") }
            } else { report("Background time is limited. Backup continues while AsterOS is open.") }
        } else { report("You can use other tabs. iOS allows only limited time after switching apps on this iOS version.") }
    }
    func update(completed: Int, total: Int, fraction: Double, status: String) {
        guard active else { return }
        let fraction = fraction.isFinite ? min(0.99, max(0, fraction)) : 0
        let units: Int64 = total > 0 ? Int64(min(999_999_999, (Double(completed) + fraction) / Double(total) * 1_000_000_000)) : 0
        lastProgress = max(lastProgress, units)
        if #available(iOS 26.0, *), let continued = continued as? BGContinuedProcessingTask {
            continued.progress.completedUnitCount = lastProgress
            let subtitle = total > 0 ? "\(completed) of \(total) items · \(status)" : status
            if subtitle != lastSubtitle {
                lastSubtitle = subtitle
                continued.updateTitle("Photo backup", subtitle: subtitle)
            }
        }
    }
    private func expire(_ source: PhotoBackupBackgroundOwnership.Owner) {
        guard active, ownership.expire(source) else { return }
        let reason = source == .temporary
            ? "Limited background time ended · tap Back up now to resume"
            : "iOS ended background backup or Stop was pressed · tap Back up now to resume"
        report?(reason)
        stop?(reason)
        finish(success: false)
    }
    private func endLease() {
        if lease != .invalid { UIApplication.shared.endBackgroundTask(lease); lease = .invalid }
    }
    func finish(success: Bool) {
        guard active else { return }
        active = false
        ownership.finish()
        if #available(iOS 26.0, *), let continued = continued as? BGContinuedProcessingTask, success {
            continued.progress.completedUnitCount = continued.progress.totalUnitCount
        }
        continued?.setTaskCompleted(success: success); continued = nil
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        endLease(); stop = nil; report = nil
    }
}
