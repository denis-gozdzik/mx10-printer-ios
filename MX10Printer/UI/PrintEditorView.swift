import PhotosUI
import SwiftUI
import UIKit

struct PrintEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var documentStore: PrintDocumentStore
    @ObservedObject var bluetoothManager: MX10BluetoothManager
    @ObservedObject var preferencesStore: PrintingPreferencesStore
    @ObservedObject var printQueue: PrintQueue

    @State private var document: PrintDocument
    @State private var selectedElementID: UUID?
    @State private var photoSelection: PhotosPickerItem?
    @State private var isPreviewMode = false
    @State private var previewImage: CGImage?
    @State private var moveStartFrames: [UUID: PrintElementFrame] = [:]
    @State private var resizeStartFrames: [UUID: PrintElementFrame] = [:]
    @State private var statusMessage: String?

    private let jobBuilder = PrintJobBuilder()

    init(
        document: PrintDocument,
        documentStore: PrintDocumentStore,
        bluetoothManager: MX10BluetoothManager,
        preferencesStore: PrintingPreferencesStore,
        printQueue: PrintQueue
    ) {
        self.documentStore = documentStore
        self.bluetoothManager = bluetoothManager
        self.preferencesStore = preferencesStore
        self.printQueue = printQueue
        _document = State(initialValue: document)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    titleEditor
                    editorToolbar
                    queueStatus
                    canvas
                    elementInspector
                }
                .padding()
            }
            .navigationTitle("Print Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        saveDocument()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveDocument()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            refreshPreview()
        }
        .onChange(of: photoSelection) { _, newValue in
            Task {
                await addImage(from: newValue)
            }
        }
        .onChange(of: preferencesStore.preferences) { _, _ in
            refreshPreview()
        }
    }

    private var titleEditor: some View {
        TextField("Document title", text: titleBinding)
            .textFieldStyle(.roundedBorder)
            .font(.headline)
    }

    private var editorToolbar: some View {
        HStack(spacing: 12) {
            Button {
                selectedElementID = document.addTextElement()
                saveDocument()
                refreshPreview()
            } label: {
                Label("Text", systemImage: "textformat")
            }

            PhotosPicker(selection: $photoSelection, matching: .images) {
                Label("Image", systemImage: "photo")
            }

            Button {
                isPreviewMode.toggle()
                refreshPreview()
            } label: {
                Label(isPreviewMode ? "Editor" : "Preview", systemImage: isPreviewMode ? "rectangle.and.pencil.and.ellipsis" : "eye")
            }

            Button {
                printCurrentDocument()
            } label: {
                Label("Print", systemImage: "printer")
            }
            .disabled(!bluetoothManager.canSendPrintData || printQueue.isPrinting)
        }
        .buttonStyle(.bordered)
    }

    private var queueStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Queue")
                .font(.headline)
            Text("Printing: \(printQueue.isPrinting ? "YES" : "NO")")
            Text("Pending jobs: \(printQueue.pendingJobs.count)")
            Text("Completed jobs: \(printQueue.completedJobs.count)")

            if let failure = printQueue.failedJobs.last {
                Text("Last failure: \(failure.message)")
                    .foregroundStyle(.red)
            } else if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }

    private var canvas: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Color.white

                if isPreviewMode {
                    if let previewImage {
                        Image(decorative: previewImage, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .frame(
                                width: CGFloat(PrintDocument.pageWidth),
                                height: CGFloat(previewImage.height)
                            )
                    } else {
                        Text("Preview unavailable")
                            .foregroundStyle(.secondary)
                            .frame(
                                width: CGFloat(PrintDocument.pageWidth),
                                height: CGFloat(document.firstPage.height)
                            )
                    }
                } else {
                    ForEach(document.firstPage.elements) { element in
                        elementLayer(element)
                    }
                }
            }
            .frame(
                width: CGFloat(PrintDocument.pageWidth),
                height: CGFloat(document.firstPage.height)
            )
            .background(Color.white)
            .overlay {
                Rectangle()
                    .stroke(Color.secondary, lineWidth: 1)
            }
            .onTapGesture {
                selectedElementID = nil
            }
        }
        .frame(maxHeight: 520)
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder
    private var elementInspector: some View {
        if let selectedElement {
            VStack(alignment: .leading, spacing: 14) {
                Text("Selected element")
                    .font(.headline)

                switch selectedElement {
                case .text:
                    textInspector
                case .image:
                    imageInspector
                }

                HStack {
                    Button("Duplicate") {
                        duplicateSelectedElement()
                    }

                    Button("Delete", role: .destructive) {
                        deleteSelectedElement()
                    }
                }
                .buttonStyle(.bordered)
            }
        } else {
            Text("No element selected")
                .foregroundStyle(.secondary)
        }
    }

    private var textInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: selectedTextBinding)
                .frame(minHeight: 96)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.35))
                }

            VStack(alignment: .leading) {
                Text("Font size: \(Int(selectedTextElement?.fontSize ?? 28))")
                Slider(value: selectedTextFontSizeBinding, in: 10...80, step: 1)
            }

            Toggle("Bold", isOn: selectedTextBoldBinding)

            Picker("Alignment", selection: selectedTextAlignmentBinding) {
                ForEach(PrintTextAlignment.allCases) { alignment in
                    Text(alignment.title).tag(alignment)
                }
            }
            .pickerStyle(.segmented)

            Picker("Ink", selection: selectedTextInkBinding) {
                ForEach(PrintInk.allCases) { ink in
                    Text(ink.title).tag(ink)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var imageInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Image mode", selection: selectedImageContentModeBinding) {
                ForEach(PrintImageContentMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Invert", isOn: selectedImageInvertBinding)

            HStack {
                Button("Rotate 90") {
                    updateSelectedImage { imageElement in
                        imageElement.rotationDegrees = (imageElement.rotationDegrees + 90).truncatingRemainder(dividingBy: 360)
                    }
                }

                Button("Crop center") {
                    updateSelectedImage { imageElement in
                        imageElement.cropRect = NormalizedCropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
                    }
                }

                Button("Reset crop") {
                    updateSelectedImage { imageElement in
                        imageElement.cropRect = .full
                    }
                }
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func elementLayer(_ element: PrintElement) -> some View {
        let frame = element.frame
        let isSelected = selectedElementID == element.id

        elementContent(element)
            .frame(width: CGFloat(frame.width), height: CGFloat(frame.height))
            .background(Color.clear)
            .overlay {
                Rectangle()
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelected {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 18, height: 18)
                        .gesture(resizeGesture(for: element.id))
                }
            }
            .rotationEffect(.degrees(element.rotationDegrees))
            .position(
                x: CGFloat(frame.x + frame.width / 2),
                y: CGFloat(frame.y + frame.height / 2)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                selectedElementID = element.id
            }
            .gesture(moveGesture(for: element.id))
    }

    @ViewBuilder
    private func elementContent(_ element: PrintElement) -> some View {
        switch element {
        case .text(let textElement):
            Text(textElement.text)
                .font(.system(size: CGFloat(textElement.fontSize), weight: textElement.isBold ? .bold : .regular))
                .foregroundStyle(textElement.ink == .black ? Color.black : Color.white)
                .multilineTextAlignment(textElement.alignment.swiftUITextAlignment)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: textElement.alignment.swiftUIFrameAlignment)

        case .image(let imageElement):
            if let uiImage = UIImage(data: imageElement.imageData) {
                if imageElement.isInverted {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: imageElement.contentMode.swiftUIContentMode)
                        .colorInvert()
                        .clipped()
                } else {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: imageElement.contentMode.swiftUIContentMode)
                        .clipped()
                }
            } else {
                Color.gray.opacity(0.2)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }

    private func moveGesture(for elementID: UUID) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if moveStartFrames[elementID] == nil {
                    moveStartFrames[elementID] = frame(for: elementID)
                    selectedElementID = elementID
                }

                guard let startFrame = moveStartFrames[elementID] else {
                    return
                }

                let updatedFrame = startFrame.offsetBy(
                    dx: Double(value.translation.width),
                    dy: Double(value.translation.height)
                )
                updateElement(id: elementID, persist: false) { element in
                    element.frame = updatedFrame
                }
            }
            .onEnded { _ in
                moveStartFrames[elementID] = nil
                saveDocument()
                refreshPreview()
            }
    }

    private func resizeGesture(for elementID: UUID) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if resizeStartFrames[elementID] == nil {
                    resizeStartFrames[elementID] = frame(for: elementID)
                    selectedElementID = elementID
                }

                guard let startFrame = resizeStartFrames[elementID] else {
                    return
                }

                let updatedFrame = startFrame.resizedBy(
                    dw: Double(value.translation.width),
                    dh: Double(value.translation.height)
                )
                updateElement(id: elementID, persist: false) { element in
                    element.frame = updatedFrame
                }
            }
            .onEnded { _ in
                resizeStartFrames[elementID] = nil
                saveDocument()
                refreshPreview()
            }
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { document.title },
            set: { newTitle in
                document.title = newTitle
                saveDocument()
            }
        )
    }

    private var selectedElement: PrintElement? {
        guard let selectedElementID else {
            return nil
        }

        return document.firstPage.elements.first { $0.id == selectedElementID }
    }

    private var selectedTextElement: TextElement? {
        guard case .text(let element) = selectedElement else {
            return nil
        }

        return element
    }

    private var selectedTextBinding: Binding<String> {
        Binding(
            get: { selectedTextElement?.text ?? "" },
            set: { newText in
                updateSelectedText { textElement in
                    textElement.text = newText
                }
            }
        )
    }

    private var selectedTextFontSizeBinding: Binding<Double> {
        Binding(
            get: { selectedTextElement?.fontSize ?? 28 },
            set: { newSize in
                updateSelectedText { textElement in
                    textElement.fontSize = newSize
                }
            }
        )
    }

    private var selectedTextBoldBinding: Binding<Bool> {
        Binding(
            get: { selectedTextElement?.isBold ?? false },
            set: { isBold in
                updateSelectedText { textElement in
                    textElement.isBold = isBold
                }
            }
        )
    }

    private var selectedTextAlignmentBinding: Binding<PrintTextAlignment> {
        Binding(
            get: { selectedTextElement?.alignment ?? .leading },
            set: { alignment in
                updateSelectedText { textElement in
                    textElement.alignment = alignment
                }
            }
        )
    }

    private var selectedTextInkBinding: Binding<PrintInk> {
        Binding(
            get: { selectedTextElement?.ink ?? .black },
            set: { ink in
                updateSelectedText { textElement in
                    textElement.ink = ink
                }
            }
        )
    }

    private var selectedImageElement: ImageElement? {
        guard case .image(let element) = selectedElement else {
            return nil
        }

        return element
    }

    private var selectedImageContentModeBinding: Binding<PrintImageContentMode> {
        Binding(
            get: { selectedImageElement?.contentMode ?? .fit },
            set: { contentMode in
                updateSelectedImage { imageElement in
                    imageElement.contentMode = contentMode
                }
            }
        )
    }

    private var selectedImageInvertBinding: Binding<Bool> {
        Binding(
            get: { selectedImageElement?.isInverted ?? false },
            set: { isInverted in
                updateSelectedImage { imageElement in
                    imageElement.isInverted = isInverted
                }
            }
        )
    }

    private func addImage(from item: PhotosPickerItem?) async {
        guard let item,
              let data = try? await item.loadTransferable(type: Data.self) else {
            return
        }

        await MainActor.run {
            selectedElementID = document.addImageElement(imageData: data)
            photoSelection = nil
            saveDocument()
            refreshPreview()
        }
    }

    private func updateSelectedText(_ update: (inout TextElement) -> Void) {
        guard let selectedElementID else {
            return
        }

        updateElement(id: selectedElementID) { element in
            guard case .text(var textElement) = element else {
                return
            }

            update(&textElement)
            element = .text(textElement)
        }
    }

    private func updateSelectedImage(_ update: (inout ImageElement) -> Void) {
        guard let selectedElementID else {
            return
        }

        updateElement(id: selectedElementID) { element in
            guard case .image(var imageElement) = element else {
                return
            }

            update(&imageElement)
            imageElement.cropRect = imageElement.cropRect.clamped()
            element = .image(imageElement)
        }
    }

    private func updateElement(id: UUID, persist: Bool = true, update: (inout PrintElement) -> Void) {
        document.updateElement(id: id, update: update)

        if persist {
            saveDocument()
            refreshPreview()
        }
    }

    private func duplicateSelectedElement() {
        guard let selectedElementID,
              let duplicateID = document.duplicateElement(id: selectedElementID) else {
            return
        }

        self.selectedElementID = duplicateID
        saveDocument()
        refreshPreview()
    }

    private func deleteSelectedElement() {
        guard let selectedElementID else {
            return
        }

        document.deleteElement(id: selectedElementID)
        self.selectedElementID = nil
        saveDocument()
        refreshPreview()
    }

    private func frame(for elementID: UUID) -> PrintElementFrame? {
        document.firstPage.elements.first { $0.id == elementID }?.frame
    }

    private func refreshPreview() {
        let preview = jobBuilder.makePreview(
            document: document,
            preferences: preferencesStore.preferences
        )
        previewImage = preview.previewImage
    }

    private func saveDocument() {
        documentStore.save(document)
    }

    private func printCurrentDocument() {
        let job = jobBuilder.makeJob(
            document: document,
            preferences: preferencesStore.preferences
        )
        documentStore.save(document)
        printQueue.enqueue(job, printer: MX10Printer(bluetoothManager: bluetoothManager))
        statusMessage = "Queued \(job.rows.count) rows"
    }
}

private extension PrintTextAlignment {
    var swiftUITextAlignment: TextAlignment {
        switch self {
        case .leading:
            return .leading
        case .center:
            return .center
        case .trailing:
            return .trailing
        }
    }

    var swiftUIFrameAlignment: Alignment {
        switch self {
        case .leading:
            return .topLeading
        case .center:
            return .top
        case .trailing:
            return .topTrailing
        }
    }
}

private extension PrintImageContentMode {
    var swiftUIContentMode: ContentMode {
        switch self {
        case .fit:
            return .fit
        case .fill:
            return .fill
        }
    }
}
