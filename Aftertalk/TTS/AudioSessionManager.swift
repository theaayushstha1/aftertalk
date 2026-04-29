import AVFoundation
import Foundation
import Observation
import os

enum AudioSessionError: Error, CustomStringConvertible {
    case configureFailed(any Error)
    case activateFailed(any Error)

    var description: String {
        switch self {
        case .configureFailed(let e): return "Audio session configure failed: \(e)"
        case .activateFailed(let e): return "Audio session activate failed: \(e)"
        }
    }
}

/// Public observable view of audio-session interruption state. Surfaced by
/// `AudioInterruptionObserver` so view models / UI can react without
/// touching `AVAudioSession` themselves.
///
/// - `.normal` — no active interruption.
/// - `.interrupted` — phone call / Siri / FaceTime began. Engine is paused;
///   recording (if any) is frozen but not torn down.
/// - `.routeChanged(reason)` — output device disappeared (AirPods unplugged,
///   bluetooth dropout). Engine paused so we don't blast audio out the iPhone
///   speaker mid-meeting; UI shows a banner; recording flags itself
///   interrupted so the user knows playback / capture stopped.
enum InterruptionState: Equatable, Sendable {
    case normal
    case interrupted
    case routeChanged(reason: String)
}

actor AudioSessionManager {
    static let shared = AudioSessionManager()

    /// Tracks the active configuration so back-to-back transitions skip the
    /// expensive setCategory + setActive dance when nothing actually changed.
    enum Mode: Equatable { case none, recording, voiceChat, voiceQuestion }
    private var mode: Mode = .none

    private init() {}

    /// Meeting-capture mode: `.record` + `.measurement` for clean,
    /// minimally-processed mic input that keeps Parakeet/Moonshine WER low.
    /// Output is disabled in this category — do **not** call this if a TTS
    /// playback is about to follow.
    func configureForRecording() throws(AudioSessionError) {
        if mode == .recording { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
        } catch {
            throw .configureFailed(error)
        }
        do {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw .activateFailed(error)
        }
        mode = .recording
    }

    /// Q&A listening mode: `.playAndRecord` + `.measurement` so the mic
    /// delivers raw, minimally-processed audio while the output bus stays
    /// available for whatever Kokoro was doing. We use this while the user
    /// holds the mic to ask a question — Apple's voice-processing IO unit
    /// (which is what `.voiceChat` engages) applies aggressive AGC, noise
    /// suppression, and a 300-3400 Hz voice band-pass that smears formants
    /// and demonstrably hurts Moonshine WER on free-form questions.
    /// `.measurement` matches what the meeting recorder uses, so question
    /// transcription quality matches meeting transcription quality. We turn
    /// AEC off here too (no TTS is playing, so there is no echo to cancel).
    /// The orchestrator flips back to `.voiceChat` before TTS starts so the
    /// barge-in mic gets AEC against Kokoro's playback bleed.
    func configureForVoiceQuestion() throws(AudioSessionError) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
        } catch {
            throw .configureFailed(error)
        }
        if #available(iOS 18.0, *) {
            try? session.setPrefersEchoCancelledInput(false)
        }
        do {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw .activateFailed(error)
        }
        mode = .voiceQuestion
    }

    /// Q&A speaking mode: `.playAndRecord` + `.voiceChat` so Kokoro plays the
    /// answer through the active session and the auto barge-in's mic gets
    /// echo cancellation against the assistant's own voice. AEC is requested
    /// via `setPrefersEchoCancelledInput`. Order is the canonical one from
    /// WWDC23/10235 — flipping it silently disables echo cancellation.
    func configureForVoiceChat() throws(AudioSessionError) {
        // No early-return on `mode == .voiceChat`. iOS can implicitly
        // deactivate the session out from under us (interruption, route
        // change, brief background) without our cached `mode` knowing,
        // which leads to setActive() failing on the *next* hold-to-ask
        // because the OS sees an active node graph against an inactive
        // session. setCategory + setActive are both effectively no-ops
        // when values already match — pay the few ms every time and
        // guarantee the session is healthy.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                // `.duckOthers` lowers any music/podcast playing in another app
                // for the duration of the TTS reply so the user hears Aftertalk
                // clearly without needing to pause Spotify first. Restored
                // automatically on deactivate via `.notifyOthersOnDeactivation`.
                options: [.defaultToSpeaker, .allowBluetooth, .duckOthers]
            )
        } catch {
            throw .configureFailed(error)
        }
        // setPrefersEchoCancelledInput is iOS 18+; available on our iOS 26 target.
        if #available(iOS 18.0, *) {
            try? session.setPrefersEchoCancelledInput(true)
        }
        do {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw .activateFailed(error)
        }
        mode = .voiceChat
    }

    /// Re-activate the session after an interruption ends + the OS asked us
    /// to resume (`AVAudioSession.InterruptionOptions.shouldResume`). Does
    /// not touch category/mode — those are sticky across interruptions.
    func reactivateAfterInterruption() throws(AudioSessionError) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw .activateFailed(error)
        }
    }

    /// Tear down the active audio session. Default behavior **skips teardown
    /// when a meeting recording is live** — chat views (`GlobalChatView`,
    /// `MeetingDetailView`, `ChatThreadView`) call this from `.onDisappear`,
    /// and a tab switch while recording would otherwise kill the engine
    /// underneath the still-running mic tap. Pass `force: true` from the
    /// recording owner (`RecordingViewModel.stop`) to actually release the
    /// session at end of meeting.
    func deactivate(force: Bool = false) {
        if !force, mode == .recording { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        mode = .none
    }
}

/// Listens for `AVAudioSession.interruptionNotification` +
/// `routeChangeNotification` once at startup and surfaces the result as a
/// main-actor observable `interruptionState` so the recording VM, Q&A
/// orchestrator, and UI can all react.
///
/// The observer is intentionally *not* the same actor as
/// `AudioSessionManager`. The session manager is a serial actor because its
/// only job is to enqueue setCategory / setActive transitions safely; the
/// observer is a `@MainActor @Observable` so SwiftUI can read state directly
/// and so view-model callbacks (engine pause/resume, TTS cancel, perf event)
/// run on the main actor without manual hops at every call site.
///
/// Wiring (done once at app start in `AftertalkApp.init` / `.onAppear`):
///   1. `observer.onInterruptionBegan = { [weak recording] in await recording?.handleInterruptionBegan() }`
///   2. `observer.onInterruptionEnded = { [weak recording, weak perf] resume in ... }`
///   3. `observer.onRouteChanged = { ... }`
///   4. `observer.start()`
///
/// Why a separate type: keeping notification-center plumbing out of the
/// audio session actor avoids re-entrancy gotchas (notification handlers
/// can fire while the actor is mid-`setCategory`), and the observable
/// surface plays nicely with `@Environment` if a future UI surface wants
/// to render the banner without going through the recording VM.
@MainActor
@Observable
final class AudioInterruptionObserver {
    /// Public, observable. Drives the "interrupted" badge in the recording
    /// surface and any future banner UI for route changes.
    var interruptionState: InterruptionState = .normal

    /// Set by the wiring code in `AftertalkApp`. Called when iOS posts
    /// `.began` — implementations should pause the engine, persist whatever
    /// partial state is safe to persist, and cancel TTS playback so audio
    /// focus snaps to the caller.
    var onInterruptionBegan: (@MainActor () async -> Void)?

    /// Called when iOS posts `.ended`. The Bool indicates whether the
    /// notification's options contained `.shouldResume` — if false, the
    /// caller should leave the recording in `.interrupted` state and let the
    /// user decide what to do next.
    var onInterruptionEnded: (@MainActor (_ shouldResume: Bool) async -> Void)?

    /// Called on `.oldDeviceUnavailable` (AirPods unplugged, BT dropout).
    /// Implementations should pause the engine and surface a banner.
    var onRouteChanged: (@MainActor (_ reason: String) async -> Void)?

    private let log = Logger(subsystem: "com.theaayushstha.aftertalk", category: "AudioInterruption")
    private var interruptionTask: Task<Void, Never>?
    private var routeChangeTask: Task<Void, Never>?
    private var started = false

    init() {}

    /// Register notification observers. Idempotent — a second call is a
    /// no-op so `AftertalkApp.onAppear` can fire it without worrying about
    /// scene-phase replays.
    func start() {
        guard !started else { return }
        started = true

        let interruptionStream = NotificationCenter.default.notifications(
            named: AVAudioSession.interruptionNotification
        )
        interruptionTask = Task { [weak self] in
            for await note in interruptionStream {
                guard !Task.isCancelled else { return }
                let info = note.userInfo
                let typeRaw = info?[AVAudioSessionInterruptionTypeKey] as? UInt
                let optionsRaw = info?[AVAudioSessionInterruptionOptionKey] as? UInt
                // Hop to MainActor so callbacks + state mutation are all on
                // the same isolation domain. The notification stream itself
                // is non-isolated, so this Task @MainActor pattern is the
                // canonical Swift 6 way to bridge.
                await self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw)
            }
        }

        let routeStream = NotificationCenter.default.notifications(
            named: AVAudioSession.routeChangeNotification
        )
        routeChangeTask = Task { [weak self] in
            for await note in routeStream {
                guard !Task.isCancelled else { return }
                let info = note.userInfo
                let reasonRaw = info?[AVAudioSessionRouteChangeReasonKey] as? UInt
                await self?.handleRouteChange(reasonRaw: reasonRaw)
            }
        }

        log.debug("AudioInterruptionObserver started")
    }

    /// Tear down observers. Mostly here for tests / hot-reload scenarios —
    /// the production app keeps the observer alive for the entire foreground
    /// lifetime so we don't miss interruptions during edge transitions.
    func stop() {
        interruptionTask?.cancel()
        interruptionTask = nil
        routeChangeTask?.cancel()
        routeChangeTask = nil
        started = false
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) async {
        guard let raw = typeRaw,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            log.debug("interruption .began")
            interruptionState = .interrupted
            await onInterruptionBegan?()

        case .ended:
            let shouldResume: Bool
            if let optionsRaw {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                shouldResume = options.contains(.shouldResume)
            } else {
                shouldResume = false
            }
            log.debug("interruption .ended shouldResume=\(shouldResume, privacy: .public)")
            // Try to reactivate the session before the VM resumes the engine
            // — otherwise `engine.start()` will fail on an inactive session.
            // Best-effort: if reactivation fails (e.g. another app is still
            // holding the route), the VM's resume will surface the error and
            // leave us in `.interrupted` state.
            if shouldResume {
                do {
                    try await AudioSessionManager.shared.reactivateAfterInterruption()
                } catch {
                    log.warning("session reactivate failed: \(String(describing: error), privacy: .public)")
                }
            }
            await onInterruptionEnded?(shouldResume)
            // Only flip back to .normal if we actually resumed; otherwise the
            // VM has surfaced an explicit interrupted state and we leave the
            // observable in lockstep.
            if shouldResume {
                interruptionState = .normal
            }

        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonRaw: UInt?) async {
        guard let raw = reasonRaw,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return }

        switch reason {
        case .oldDeviceUnavailable:
            // The previous output device went away — AirPods unplugged,
            // bluetooth peer disconnected, etc. Pause + banner. The user
            // can resume manually once they've resolved the route.
            let label = "output_device_unavailable"
            log.debug("routeChange \(label, privacy: .public)")
            interruptionState = .routeChanged(reason: label)
            await onRouteChanged?(label)
        default:
            // Other route reasons (newDeviceAvailable, categoryChange, ...)
            // are normal lifecycle events; we don't need to surface them.
            break
        }
    }
}
