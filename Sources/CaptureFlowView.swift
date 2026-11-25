import SwiftUI
import RealityKit

/// Guided capture with Apple's Object Capture, then on-device reconstruction to USDZ.
struct CaptureFlowView: View {
    let scan: ScanItem
    var onDone: (Bool) -> Void

    private enum Phase { case capture, reconstruct, failed }

    @State private var session: ObjectCaptureSession?
    @State private var captureState: ObjectCaptureSession.CaptureState = .initializing
    @State private var phase: Phase = .capture
    @State private var progress: Double = 0
    @State private var errorText = ""

    var body: some View {
        ZStack {
            switch phase {
            case .capture:
                if let session {
                    ObjectCaptureView(session: session)
                        .ignoresSafeArea()
                    captureControls(session)
                } else {
                    ProgressView()
                }
            case .reconstruct:
                VStack(spacing: 16) {
                    ProgressView(value: progress)
                        .padding(.horizontal, 40)
                    Text("בונה מודל… \(Int(progress * 100))%")
                    Text("אפשר להשאיר את המסך פתוח. זה לוקח כמה דקות.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .failed:
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(errorText).multilineTextAlignment(.center).padding()
                    Button("סגור") { onDone(false) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .task { await runCapture() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }   // keep the screen on while scanning
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    @ViewBuilder
    private func captureControls(_ session: ObjectCaptureSession) -> some View {
        VStack {
            HStack {
                Button("ביטול") {
                    session.cancel()
                    onDone(false)
                }
                .buttonStyle(.bordered)
                Spacer()
                if case .capturing = captureState {
                    Text("\(session.numberOfShotsTaken) תמונות")
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding()

            Spacer()

            VStack(spacing: 12) {
                switch captureState {
                case .ready, .initializing:
                    hint("מכין מצלמה…")
                case .detecting:
                    hint("כוון לחלק עד שהקופסה עוטפת אותו")
                    bigButton("התחל סריקה") { session.startCapturing() }
                    Button("אפס קופסה") { _ = session.resetDetection() }
                case .capturing:
                    if session.userCompletedScanPass {
                        hint("סיבוב הושלם")
                        bigButton("בנה מודל ושרטוט") { session.finish() }
                        HStack(spacing: 12) {
                            Button("הפוך את החלק וסרוק מלמטה") { session.beginNewScanPassAfterFlip() }
                            Button("סיבוב נוסף") { session.beginNewScanPass() }
                        }
                        .buttonStyle(.bordered)
                    } else {
                        hint("הקף את החלק לאט")
                        Button("סיים עכשיו") { session.finish() }
                            .buttonStyle(.bordered)
                    }
                case .finishing:
                    ProgressView("מסיים צילום…")
                default:
                    EmptyView()
                }
            }
            .padding(.bottom, 32)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func bigButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
    }

    @MainActor
    private func runCapture() async {
        guard ObjectCaptureSession.isSupported else {
            errorText = "המכשיר הזה לא תומך בסריקת אובייקטים. צריך iPhone Pro עם LiDAR."
            phase = .failed
            return
        }
        let newSession = ObjectCaptureSession()
        var config = ObjectCaptureSession.Configuration()
        config.checkpointDirectory = scan.checkpointURL
        newSession.start(imagesDirectory: scan.imagesURL, configuration: config)
        session = newSession

        for await state in newSession.stateUpdates {
            captureState = state
            switch state {
            case .ready:
                _ = newSession.startDetecting()   // skip a tap: go straight to framing the part
            case .completed:
                phase = .reconstruct
                session = nil          // release the capture session before reconstruction
                await reconstruct()
                return
            case .failed(let error):
                errorText = "הסריקה נכשלה: \(error.localizedDescription)"
                phase = .failed
                return
            default:
                break
            }
        }
    }

    @MainActor
    private func reconstruct() async {
        do {
            var config = PhotogrammetrySession.Configuration()
            config.checkpointDirectory = scan.checkpointURL
            let photogrammetry = try PhotogrammetrySession(input: scan.imagesURL, configuration: config)
            try photogrammetry.process(requests: [.modelFile(url: scan.modelURL)])
            for try await output in photogrammetry.outputs {
                switch output {
                case .requestProgress(_, let fraction):
                    progress = fraction
                case .requestError(_, let error):
                    throw error
                case .processingComplete:
                    onDone(true)
                    return
                case .processingCancelled:
                    onDone(false)
                    return
                default:
                    break
                }
            }
        } catch {
            errorText = "בניית המודל נכשלה: \(error.localizedDescription)"
            phase = .failed
        }
    }
}
