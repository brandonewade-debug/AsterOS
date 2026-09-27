import UIKit
import BackgroundTasks

/// One lease per explicit backup run. Never schedules unattended future backups.
@MainActor final class PhotoBackupExecution {
    private let identifier = (Bundle.main.bundleIdentifier ?? "com.asterlinelabs.asteros") + ".photo-backup." + UUID().uuidString
    private var lease: UIBackgroundTaskIdentifier = .invalid
    private var continued: BGTask?
    private var active = true
    private var stop: (() -> Void)?
    private var report: ((String) -> Void)?
    private var lastProgress: Int64 = 0
    private var lastSubtitle = ""
    var allowsBackground: Bool { active && (continued != nil || lease != .invalid) }

    init(stop: @escaping () -> Void, report: @escaping (String) -> Void) {
        self.stop = stop; self.report = report
        lease = UIApplication.shared.beginBackgroundTask(withName: "Photo backup") { [weak self] in
            Task { @MainActor in self?.expire() }
        }
        if #available(iOS 26.0, *) {
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
                Task { @MainActor in
                    guard let self, self.active, let task = task as? BGContinuedProcessingTask else {
                        task.setTaskCompleted(success: false); return
                    }
                    self.continued = task
                    task.progress.totalUnitCount = 1_000_000
                    task.progress.completedUnitCount = self.lastProgress
                    task.expirationHandler = { [weak self] in Task { @MainActor in self?.expire() } }
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
        let units: Int64 = total > 0 ? Int64(min(999_999, (Double(completed) + fraction) / Double(total) * 1_000_000)) : 0
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
    private func expire() {
        guard active else { return }
        stop?()
        finish(success: false)
    }
    private func endLease() {
        if lease != .invalid { UIApplication.shared.endBackgroundTask(lease); lease = .invalid }
    }
    func finish(success: Bool) {
        guard active else { return }
        active = false
        if #available(iOS 26.0, *), let continued = continued as? BGContinuedProcessingTask, success {
            continued.progress.completedUnitCount = continued.progress.totalUnitCount
        }
        continued?.setTaskCompleted(success: success); continued = nil
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        endLease(); stop = nil; report = nil
    }
}
