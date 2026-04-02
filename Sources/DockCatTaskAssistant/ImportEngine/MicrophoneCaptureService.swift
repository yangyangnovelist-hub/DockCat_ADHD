import AVFoundation
import Combine
import Foundation

@MainActor
final class MicrophoneCaptureService: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var statusMessage: String?

    private var recorder: AVAudioRecorder?
    private var activeFileURL: URL?

    func startRecording() async throws {
        guard !isRecording else { return }
        let granted = await requestPermission()
        guard granted else {
            throw MicrophoneCaptureError.permissionDenied
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dockcat-capture-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw MicrophoneCaptureError.startFailed
        }

        self.recorder = recorder
        self.activeFileURL = outputURL
        self.isRecording = true
        self.statusMessage = "麦克风录音中，再点一次会停止并转写。"
    }

    func stopRecording() async throws -> URL? {
        guard isRecording else { return nil }
        recorder?.stop()

        let fileURL = activeFileURL
        recorder = nil
        activeFileURL = nil
        isRecording = false
        statusMessage = "录音完成，正在转写语音。"
        return fileURL
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

enum MicrophoneCaptureError: LocalizedError {
    case permissionDenied
    case startFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "没有拿到麦克风权限，请在系统设置里允许访问麦克风。"
        case .startFailed:
            "麦克风启动失败，请确认当前没有被其他录音应用占用。"
        }
    }
}
