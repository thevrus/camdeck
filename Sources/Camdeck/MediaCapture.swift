import AVFoundation
import Foundation

/// Stills and movies from the live session. Photos go to ~/Pictures/Camdeck, movies to ~/Movies/Camdeck.
/// The microphone joins the session only while a movie records, so the mic indicator is off the rest of the time.
/// All session work runs on the controller's session queue; results come back on the main actor.
final class MediaCapture: NSObject, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let photoOutput = AVCapturePhotoOutput()
    let movieOutput = AVCaptureMovieFileOutput()
    private var audioInput: AVCaptureDeviceInput?   // session queue only
    private var photoDone: [Int64: @MainActor (Result<URL, Error>) -> Void] = [:]
    private let lock = NSLock()
    /// Called on the main actor when the first frames reach the file (adding the microphone takes a moment).
    var onMovieStarted: (@MainActor () -> Void)?
    /// Called on the main actor when a movie finishes writing (or fails).
    var onMovieFinished: (@MainActor (Result<URL, Error>) -> Void)?

    /// Follows the preview's mirroring, so what is saved looks like what was on screen. Session queue.
    var mirrored = true { didSet { applyMirroring() } }

    /// Adds the photo and movie outputs. Session queue, inside a configuration.
    func attach(to session: AVCaptureSession) {
        for o in [photoOutput, movieOutput] as [AVCaptureOutput] where session.canAddOutput(o) { session.addOutput(o) }
    }

    /// Call after the camera input changes: new input, new connections, mirroring set again. Session queue.
    func applyMirroring() {
        for output in [photoOutput, movieOutput] as [AVCaptureOutput] {
            guard let c = output.connection(with: .video), c.isVideoMirroringSupported else { continue }
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = mirrored
        }
    }

    // MARK: Photo

    func takePhoto(done: @escaping @MainActor (Result<URL, Error>) -> Void) {
        let settings = photoOutput.availablePhotoCodecTypes.contains(.jpeg)
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            : AVCapturePhotoSettings()
        lock.lock(); photoDone[settings.uniqueID] = done; lock.unlock()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        lock.lock(); let done = photoDone.removeValue(forKey: photo.resolvedSettings.uniqueID); lock.unlock()
        let result: Result<URL, Error> = Result {
            if let error { throw error }
            guard let data = photo.fileDataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
            let url = try Self.newFile(in: .picturesDirectory, ext: "jpg")
            try data.write(to: url)
            return url
        }
        if let done { Task { @MainActor in done(result) } }
    }

    // MARK: Movie

    /// Starts a movie. `withAudio` adds the default microphone for this recording.
    func startRecording(on session: AVCaptureSession, withAudio: Bool) throws {
        if withAudio, audioInput == nil, let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic) {
            session.beginConfiguration()
            if session.canAddInput(input) { session.addInput(input); audioInput = input }
            session.commitConfiguration()
        }
        movieOutput.startRecording(to: try Self.newFile(in: .moviesDirectory, ext: "mov"), recordingDelegate: self)
    }

    func stopRecording() { movieOutput.stopRecording() }

    /// Takes the microphone out of the session once a movie is done. Session queue.
    func detachAudio(from session: AVCaptureSession) {
        guard let input = audioInput else { return }
        audioInput = nil
        guard session.inputs.contains(input) else { return }
        session.beginConfiguration()
        session.removeInput(input)
        session.commitConfiguration()
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo url: URL, from connections: [AVCaptureConnection]) {
        let started = onMovieStarted
        Task { @MainActor in started?() }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        // A movie that stopped on an error can still be complete; AVFoundation says so in the userInfo.
        let finished = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool
        let result: Result<URL, Error> = error == nil || finished == true ? .success(url) : .failure(error!)
        if case .failure = result { try? FileManager.default.removeItem(at: url) }   // an empty or broken file
        let done = onMovieFinished
        Task { @MainActor in done?(result) }
    }

    // MARK: Files

    private static let fileDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    /// "~/Pictures/Camdeck/Camdeck 2026-11-04 at 13.25.51.jpg", with " 2" and up when that name is taken.
    private static func newFile(in dir: FileManager.SearchPathDirectory, ext: String) throws -> URL {
        let folder = try FileManager.default.url(for: dir, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("Camdeck", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = "Camdeck \(fileDate.string(from: Date()))"
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).\(ext)"); n += 1
        }
        return url
    }
}
