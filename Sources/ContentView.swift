import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ScanStore
    @State private var capturing: ScanItem?
    @State private var path: [ScanItem] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if store.scans.isEmpty {
                    Text("אין סריקות עדיין. לחץ על \"סריקה חדשה\" וכוון את הטלפון לחלק.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.scans) { scan in
                    NavigationLink(value: scan) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(scan.meta.name).font(.headline)
                            Text(scan.hasModel ? "מודל מוכן" : "אין מודל")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    let doomed = offsets.map { store.scans[$0] }
                    doomed.forEach(store.delete)
                }
            }
            .navigationTitle("סורק 3D")
            .navigationDestination(for: ScanItem.self) { scan in
                ScanDetailView(scan: scan)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    capturing = store.newScan()
                } label: {
                    Label("סריקה חדשה", systemImage: "camera.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
            }
        }
        .fullScreenCover(item: $capturing) { scan in
            CaptureFlowView(scan: scan) { success in
                capturing = nil
                store.reload()
                if success, let done = store.scan(withID: scan.id) {
                    path.append(done)
                } else if let leftover = store.scan(withID: scan.id), !leftover.hasModel {
                    store.delete(leftover)
                }
            }
        }
    }
}
