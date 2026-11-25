import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ScanStore
    @State private var capturing: ScanItem?
    @State private var path: [ScanItem] = []

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if store.scans.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(store.scans) { scan in
                            NavigationLink(value: scan) {
                                ScanCard(scan: scan)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.delete(scan)
                                } label: {
                                    Label("מחק סריקה", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 130)
                }
            }
            .navigationTitle("הסריקות שלי")
            .navigationDestination(for: ScanItem.self) { scan in
                ScanDetailView(scan: scan)
            }
            .overlay(alignment: .bottom) { scanButton }
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

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
                .padding(.top, 80)
            Text("סרוק את החלק הראשון שלך")
                .font(.title2.bold())
            Text("לחץ על כפתור הסריקה, כוון את הטלפון לחלק והקף אותו. בסוף תקבל מודל 3D ושרטוט עם מידות.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
    }

    private var scanButton: some View {
        Button {
            capturing = store.newScan()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(.tint)
                        .frame(width: 78, height: 78)
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                    Image(systemName: "viewfinder")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.black)
                }
                Text("סריקה חדשה")
                    .font(.footnote.weight(.semibold))
            }
        }
        .buttonStyle(.plain)
        .padding(.bottom, 20)
    }
}

private struct ScanCard: View {
    let scan: ScanItem
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(white: 0.13))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                } else if scan.hasModel {
                    ProgressView()
                } else {
                    Image(systemName: "cube.transparent")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(1, contentMode: .fit)

            Text(scan.meta.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(scan.meta.created, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: scan.id) {
            guard image == nil else { return }
            let item = scan
            image = await Task.detached(priority: .utility) { Thumbnailer.image(for: item) }.value
        }
    }
}
