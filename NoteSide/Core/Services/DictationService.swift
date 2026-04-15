import AppKit
import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class DictationService: ObservableObject {
    enum State: Equatable {
        case idle
        case listening
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var partialTranscript = ""
    @Published private(set) var isMicrophoneAuthorized = false
    @Published private(set) var isSpeechRecognitionAuthorized = false

    var isFullyAuthorized: Bool {
        isMicrophoneAuthorized && isSpeechRecognitionAuthorized
    }

    private let speechRecognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
        refreshPermissionStatus()
    }

    // MARK: - Permissions

    func refreshPermissionStatus() {
        isMicrophoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        isSpeechRecognitionAuthorized = SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    func requestMicrophonePermission() {
        let currentStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        if currentStatus == .notDetermined {
            // Activate the app so the system dialog appears in front.
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor [weak self] in
                    self?.isMicrophoneAuthorized = granted
                }
            }
        } else if currentStatus == .authorized {
            isMicrophoneAuthorized = true
        } else {
            openSystemSettings(privacy: "Privacy_Microphone")
        }
    }

    func requestSpeechRecognitionPermission() {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()

        if currentStatus == .notDetermined {
            NSApp.activate(ignoringOtherApps: true)
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.isSpeechRecognitionAuthorized = status == .authorized
                }
            }
        } else if currentStatus == .authorized {
            isSpeechRecognitionAuthorized = true
        } else {
            openSystemSettings(privacy: "Privacy_SpeechRecognition")
        }
    }

    private func openSystemSettings(privacy suffix: String) {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(suffix)",
            "x-apple.systempreferences:com.apple.preference.security?\(suffix)"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    // MARK: - Recording

    func startListening() {
        guard state == .idle else { return }

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            state = .failed("Speech recognition is not available.")
            scheduleResetToIdle()
            return
        }

        guard speechRecognizer.supportsOnDeviceRecognition else {
            state = .failed("On-device speech recognition is not available for \(Locale.current.language.languageCode?.identifier ?? "this language").")
            scheduleResetToIdle()
            return
        }

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            state = .failed("Could not start audio: \(error.localizedDescription)")
            scheduleResetToIdle()
            return
        }

        audioEngine = engine
        recognitionRequest = request
        partialTranscript = ""

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.partialTranscript = result.bestTranscription.formattedString
                }
                if error != nil, self.state == .listening {
                    // Recognition ended unexpectedly (timeout, etc.)
                    // Keep the partial transcript — the caller will collect it on stop.
                }
            }
        }

        state = .listening
    }

    func stopListening() -> String {
        let transcript = partialTranscript

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        partialTranscript = ""
        state = .idle

        return transcript
    }

    // MARK: - Helpers

    private func scheduleResetToIdle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            if case .failed = self.state {
                self.state = .idle
            }
        }
    }
}
