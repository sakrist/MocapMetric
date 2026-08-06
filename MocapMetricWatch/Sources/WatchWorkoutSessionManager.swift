import Combine
import Foundation
import HealthKit
import OSLog

@MainActor
final class WatchWorkoutSessionManager: NSObject, ObservableObject {
    @Published private(set) var isWorkoutActive = false
    @Published private(set) var lastErrorMessage: String?

    private let healthStore = HKHealthStore()
    private let logger = Logger(subsystem: "com.sakrist.MocapMetric", category: "WatchWorkout")
    private var session: HKWorkoutSession?
    private var isStartingWorkout = false
    private var startWaiters: [CheckedContinuation<Bool, Never>] = []

    func startIfNeeded() async -> Bool {
        if isWorkoutActive {
            return true
        }
        if isStartingWorkout || session != nil {
            return await waitForWorkoutStart()
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            logger.error("Health data is unavailable on this Watch")
            lastErrorMessage = "Health data unavailable"
            return false
        }

        do {
            isStartingWorkout = true
            logger.info("Requesting workout authorization for motion recording")
            try await healthStore.requestAuthorization(
                toShare: [HKObjectType.workoutType()],
                read: []
            )
            guard isStartingWorkout else { return false }

            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .other
            configuration.locationType = .unknown

            let session = try HKWorkoutSession(
                healthStore: healthStore,
                configuration: configuration
            )
            session.delegate = self
            self.session = session
            lastErrorMessage = nil
            logger.info("Starting workout session for motion recording")
            return await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
                session.startActivity(with: Date())
            }
        } catch {
            logger.error("Workout session could not start: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
            session = nil
            isWorkoutActive = false
            isStartingWorkout = false
            finishWorkoutStart(success: false)
            return false
        }
    }

    func endIfNeeded() {
        guard let session else { return }

        logger.info("Ending workout session")
        session.end()
        self.session = nil
        isWorkoutActive = false
        isStartingWorkout = false
        finishWorkoutStart(success: false)
    }

    private func waitForWorkoutStart() async -> Bool {
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    private func finishWorkoutStart(success: Bool) {
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume(returning: success) }
    }
}

extension WatchWorkoutSessionManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            guard session === workoutSession else { return }

            logger.info("Workout session changed state. state=\(String(describing: toState), privacy: .public)")
            isWorkoutActive = toState == .running
            if toState == .running {
                isStartingWorkout = false
                lastErrorMessage = nil
                finishWorkoutStart(success: true)
            } else if toState == .ended {
                session = nil
                isStartingWorkout = false
                finishWorkoutStart(success: false)
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            guard session === workoutSession else { return }

            logger.error("Workout session failed: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
            session = nil
            isWorkoutActive = false
            isStartingWorkout = false
            finishWorkoutStart(success: false)
        }
    }
}
