import SwiftUI

private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ScanDetailView: View {
    @EnvironmentObject private var store: ScanStore
    @State var scan: ScanItem
    @StateObject private var measure = MeasureController()

    @State private var mesh: MeshData?
    @State private var sizeMeters: SIMD3<Double>?
    @State private var showCalibration = false
    @State private var caliperText = ""
    @State private var share: ShareItem?
    @State private var busy = false
    @State private var errorText: String?

    private var scale: Double { scan.meta.scale }

    var body: some View {
        VStack(spacing: 0) {
            if scan.hasModel {
                ModelSceneView(url: scan.modelURL, controller: measure)
            } else {
                ContentUnavailableView("אין מודל לסריקה הזו", systemImage: "cube.transparent")
            }
            infoPanel
        }
        .navigationTitle(scan.meta.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.title) { export(format) }
                    }
                } label: {
                    Label("ייצוא", systemImage: "square.and.arrow.up")
                }
                .disabled(mesh == nil || busy)
            }
        }
        .alert("כיול לפי קליבר", isPresented: $showCalibration) {
            TextField("מידה במ\"מ", text: $caliperText)
                .keyboardType(.decimalPad)
            Button("שמור") { applyCalibration() }
            Button("ביטול", role: .cancel) {}
        } message: {
            Text("הקלד את המידה שמדדת בקליבר בין שתי הנקודות שסימנת. כל המודל יתוקן לפיה.")
        }
        .alert("שגיאה", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("אישור", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .sheet(item: $share) { item in
            ShareSheet(url: item.url)
        }
        .task { await loadMesh() }
    }

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let size = sizeMeters {
                Text("מידות חיצוניות: \(mm(size.x)) × \(mm(size.y)) × \(mm(size.z)) מ\"מ")
                    .font(.subheadline.monospacedDigit())
            } else if scan.hasModel {
                ProgressView("מחשב מידות…")
            }

            if let d = measure.distanceMeters {
                HStack {
                    Text("מרחק: \(mm(d)) מ\"מ")
                        .font(.title3.bold().monospacedDigit())
                    Spacer()
                    Button("כיול לפי קליבר") {
                        caliperText = ""
                        showCalibration = true
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text("לחץ על שתי נקודות במודל כדי למדוד מרחק. גרירה מסובבת, צביטה מגדילה.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("נקה מדידה") { measure.clear() }
                    .disabled(measure.distanceMeters == nil)
                Spacer()
                if scale != 1.0 {
                    Text(String(format: "כיול פעיל: ×%.4f", scale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("בטל כיול") { setScale(1.0) }
                        .font(.caption)
                }
            }
        }
        .padding()
        .background(.bar)
    }

    private func mm(_ meters: Double) -> String {
        String(format: "%.1f", meters * 1000 * scale)
    }

    private func loadMesh() async {
        guard scan.hasModel, mesh == nil else { return }
        let url = scan.modelURL
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try Exporter.loadMesh(from: url)
            }.value
            mesh = loaded
            sizeMeters = await Task.detached { Exporter.orientedSize(loaded.positions) }.value
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func applyCalibration() {
        let cleaned = caliperText.replacingOccurrences(of: ",", with: ".")
        guard let realMM = Double(cleaned), realMM > 0,
              let d = measure.distanceMeters, d > 0 else {
            errorText = "המספר לא תקין"
            return
        }
        setScale(realMM / (d * 1000))
    }

    private func setScale(_ value: Double) {
        scan.meta.scale = value
        store.save(scan)
    }

    private func export(_ format: ExportFormat) {
        guard let mesh else { return }
        busy = true
        let url = scan.exportsURL.appendingPathComponent("\(scan.id).\(format.rawValue)")
        let scale = self.scale
        Task {
            do {
                try FileManager.default.createDirectory(at: scan.exportsURL, withIntermediateDirectories: true)
                try await Task.detached(priority: .userInitiated) {
                    try Exporter.export(mesh, format: format, scale: scale, to: url)
                }.value
                share = ShareItem(url: url)
            } catch {
                errorText = "הייצוא נכשל: \(error.localizedDescription)"
            }
            busy = false
        }
    }
}
