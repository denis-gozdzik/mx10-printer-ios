import SwiftUI

struct ContentView: View {
    @StateObject private var bluetoothManager = MX10BluetoothManager()
    @StateObject private var documentStore = PrintDocumentStore()
    @StateObject private var preferencesStore = PrintingPreferencesStore()
    @StateObject private var printQueue = PrintQueue()

    @State private var editorDocument: PrintDocument?
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack {
            HomeView(
                bluetoothManager: bluetoothManager,
                documentStore: documentStore,
                onNewPrint: openNewPrint,
                onOpenDocument: { editorDocument = $0 }
            )
            .navigationTitle("MX10 Printer")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
        .sheet(item: $editorDocument) { document in
            PrintEditorView(
                document: document,
                documentStore: documentStore,
                bluetoothManager: bluetoothManager,
                preferencesStore: preferencesStore,
                printQueue: printQueue
            )
        }
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack {
                SettingsView(
                    bluetoothManager: bluetoothManager,
                    preferencesStore: preferencesStore
                )
            }
        }
    }

    private func openNewPrint() {
        editorDocument = documentStore.makeBlankDocument()
    }
}

#Preview {
    ContentView()
}
