import SwiftUI
import PhotosUI

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage?) -> Void
        init(onImage: @escaping (UIImage?) -> Void) { self.onImage = onImage }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onImage(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onImage(nil)
        }
    }
}

/// Take a photo of a flat part on a white A4 sheet and get a dimensioned drawing.
struct PhotoDrawingView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Output {
        let pdf: URL
        let dxf: URL
        let check: UIImage?
        let holes: Int
        let size: SIMD2<Double>
    }

    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var thickness = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var output: Output?
    @State private var tab = 0
    @State private var share: ShareItem?

    var body: some View {
        NavigationStack {
            Group {
                if busy {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("מזהה את הדף והחלק…")
                    }
                } else if let output {
                    resultView(output)
                } else {
                    startView
                }
            }
            .navigationTitle("שרטוט מתמונה")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("סגור") { dismiss() }
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                if let image { process(image) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    process(image)
                } else {
                    errorText = "לא הצלחתי לפתוח את התמונה."
                }
            }
        }
        .alert("לא הצלחתי ליצור שרטוט", isPresented: Binding(get: { errorText != nil },
                                                               set: { if !$0 { errorText = nil } })) {
            Button("אישור", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .sheet(item: $share) { item in
            ShareSheet(url: item.url)
        }
    }

    private var startView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                VStack(alignment: .leading, spacing: 10) {
                    tip("1", "הנח דף A4 לבן על משטח כהה (שולחן עץ, משטח שחור).")
                    tip("2", "הנח את החלק השטוח על הדף, לא קרוב לשוליים.")
                    tip("3", "צלם ישר מלמעלה, כשכל ארבע הפינות של הדף בתמונה.")
                    tip("4", "תאורה רכה בלי צללים חזקים. אור יום ליד חלון עובד טוב.")
                }
                TextField("עובי החלק במ\"מ (לא חובה)", text: $thickness)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                Button {
                    showCamera = true
                } label: {
                    Label("צלם", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("בחר תמונה מהגלריה", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Text("מתאים לחלקים שטוחים כמו פח ופלטות. בחלק עבה הצד העליון נראה גדול מעט מהאמת.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private func tip(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n)
                .font(.footnote.bold())
                .frame(width: 22, height: 22)
                .background(Circle().fill(.tint.opacity(0.25)))
            Text(text)
        }
    }

    private func resultView(_ output: Output) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("שרטוט").tag(0)
                Text("בדיקת זיהוי").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            if tab == 0 {
                PDFKitView(url: output.pdf)
                    .id(output.pdf)
            } else if let check = output.check {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: check)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 900)
                }
                Text("אדום = קו המתאר שזוהה, ירוק = חורים.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
            VStack(spacing: 10) {
                Text("\(DrawingGenerator.mmText(output.size.x)) × \(DrawingGenerator.mmText(output.size.y)) מ\"מ, \(output.holes) חורים")
                    .font(.subheadline.monospacedDigit())
                HStack {
                    Button("PDF") { share = ShareItem(url: output.pdf) }
                        .buttonStyle(.borderedProminent)
                    Button("DXF") { share = ShareItem(url: output.dxf) }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("תמונה חדשה") {
                        self.output = nil
                        tab = 0
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .background(.bar)
        }
    }

    private func process(_ image: UIImage) {
        busy = true
        let t = Double(thickness.replacingOccurrences(of: ",", with: "."))
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { () throws -> Output in
                    let part = try PhotoAnalyzer.analyze(image)
                    let now = Date()
                    let idFormat = DateFormatter()
                    idFormat.locale = Locale(identifier: "en_US_POSIX")
                    idFormat.dateFormat = "yyyyMMdd-HHmmss"
                    let id = idFormat.string(from: now)
                    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let folder = docs.appendingPathComponent("PhotoDrawings/\(id)", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    if let jpg = image.jpegData(compressionQuality: 0.85) {
                        try? jpg.write(to: folder.appendingPathComponent("photo.jpg"))
                    }
                    if let png = part.check?.jpegData(compressionQuality: 0.8) {
                        try? png.write(to: folder.appendingPathComponent("check.jpg"))
                    }
                    let nameFormat = DateFormatter()
                    nameFormat.dateFormat = "d.M.yyyy HH:mm"
                    let pdf = folder.appendingPathComponent("\(id)-drawing.pdf")
                    let dxf = folder.appendingPathComponent("\(id)-drawing.dxf")
                    try PhotoDrawing.renderPDF(part, title: "חלק מתמונה " + nameFormat.string(from: now),
                                               date: now, thickness: t, to: pdf)
                    try PhotoDrawing.writeDXF(part, to: dxf)
                    return Output(pdf: pdf, dxf: dxf, check: part.check, holes: part.holes.count, size: part.size)
                }.value
                output = result
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }
}
