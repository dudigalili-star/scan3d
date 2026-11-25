import SwiftUI

/// Manual editing of the dimensions printed on the drawing.
struct DimensionsEditor: View {
    let measured: SIMD3<Double>?          // mm, from the scan
    let initial: ScanMeta
    var onSave: (ScanMeta) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var width = ""
    @State private var depth = ""
    @State private var height = ""
    @State private var extras: [ExtraDimension] = []
    @State private var extraTexts: [UUID: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row("רוחב", text: $width, scanned: measured?.x)
                    row("עומק", text: $depth, scanned: measured?.y)
                    row("גובה", text: $height, scanned: measured?.z)
                } header: {
                    Text("מידות כלליות (מ\"מ)")
                } footer: {
                    Text("שדה ריק = המידה מהסריקה. מספר שתקליד יופיע בשרטוט במקומה.")
                }

                Section("מידות נוספות בשרטוט") {
                    ForEach($extras) { $dim in
                        HStack {
                            TextField("שם, למשל קוטר חור", text: $dim.name)
                            TextField("מ\"מ", text: Binding(
                                get: { extraTexts[dim.id] ?? "" },
                                set: { extraTexts[dim.id] = $0 }))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                        }
                    }
                    .onDelete { extras.remove(atOffsets: $0) }
                    Button {
                        let dim = ExtraDimension(name: "", value: 0)
                        extras.append(dim)
                        extraTexts[dim.id] = ""
                    } label: {
                        Label("הוסף מידה", systemImage: "plus.circle")
                    }
                }

                Section {
                    Button("החזר את כל המידות הכלליות לסריקה") {
                        width = ""; depth = ""; height = ""
                    }
                }
            }
            .navigationTitle("עריכת מידות")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ביטול") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("שמור") { save() }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func row(_ title: String, text: Binding<String>, scanned: Double?) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(scanned.map { DrawingGenerator.mmText($0) } ?? "מ\"מ", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
        }
    }

    private static func parse(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let v = Double(cleaned), v > 0 else { return nil }
        return v
    }

    private func load() {
        width = initial.widthMM.map { DrawingGenerator.mmText($0) } ?? ""
        depth = initial.depthMM.map { DrawingGenerator.mmText($0) } ?? ""
        height = initial.heightMM.map { DrawingGenerator.mmText($0) } ?? ""
        extras = initial.extraDimensions ?? []
        for d in extras { extraTexts[d.id] = DrawingGenerator.mmText(d.value) }
    }

    private func save() {
        var meta = initial
        meta.widthMM = Self.parse(width)
        meta.depthMM = Self.parse(depth)
        meta.heightMM = Self.parse(height)
        meta.extraDimensions = extras.compactMap { d in
            let name = d.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let v = Self.parse(extraTexts[d.id] ?? "") else { return nil }
            var kept = d
            kept.name = name
            kept.value = v
            return kept
        }
        onSave(meta)
        dismiss()
    }
}
