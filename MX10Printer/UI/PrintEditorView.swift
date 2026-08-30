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
    @State private var latestPreview: PrintPreview?
    @State private var moveStartFrames: [UUID: PrintElementFrame] = [:]
    @State private var resizeStartFrames: [UUID: PrintElementFrame] = [:]
    @State private var statusMessage: String?
    @StateObject private var previewDebouncer = PreviewDebouncer()
    @FocusState private var isTextInspectorFocused: Bool

    private let logger = DiagnosticLogger.shared
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
        .onDisappear {
            previewDebouncer.cancel()
        }
        .onChange(of: photoSelection) { _, newValue in
            Task {
                await addImage(from: newValue)
            }
        }
        .onChange(of: preferencesStore.preferences) { _, _ in
            schedulePreviewRefresh()
        }
        .onChange(of: bluetoothManager.printerStateText) { _, newValue in
            guard printQueue.isPrinting, newValue == "Disconnected" else {
                return
            }

            printQueue.failCurrentJob(reason: "Printer disconnected")
        }
    }

    private var titleEditor: some View {
        TextField("Document title", text: titleBinding)
            .textFieldStyle(.roundedBorder)
            .font(.headline)
    }

    private var editorToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    let elementID = document.addTextElement()
                    selectedElementID = elementID
                    focusTextInspector()
                    logger.log(.editor, "text element added", metadata: ["element": elementID.uuidString])
                    saveDocument()
                    schedulePreviewRefresh()
                } label: {
                    Label("Text", systemImage: "textformat")
                }

                PhotosPicker(selection: $photoSelection, matching: .images) {
                    Label("Image", systemImage: "photo")
                }

                Button {
                    let elementID = document.addQRCodeElement()
                    selectedElementID = elementID
                    dismissEditorKeyboard()
                    logger.log(.editor, "QR element added", metadata: ["element": elementID.uuidString])
                    saveDocument()
                    schedulePreviewRefresh()
                } label: {
                    Label("QR", systemImage: "qrcode")
                }

                Button {
                    isPreviewMode.toggle()
                    refreshPreview()
                } label: {
                    Label(isPreviewMode ? "Edit" : "Preview", systemImage: isPreviewMode ? "rectangle.and.pencil.and.ellipsis" : "eye")
                }

                Button {
                    printCurrentDocument()
                } label: {
                    Label("Print", systemImage: "printer")
                }
                .disabled(printUnavailableReason != nil)

                if printQueue.isPrinting {
                    Button(role: .destructive) {
                        dismissEditorKeyboard()
                        printQueue.cancelCurrentJob()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                }
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)
            .controlSize(.regular)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func dismissEditorKeyboard() {
        isTextInspectorFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private var queueStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(printQueue.currentStatusText)
                .font(.headline)

            if printQueue.isPrinting {
                ProgressView(value: printQueue.progressFraction)
            }

            if let latestPreview {
                Text("\(BitmapRasterizer.targetWidth) px • \(latestPreview.printRowCount) rows")
                    .foregroundStyle(.secondary)
            }

            if let reason = printUnavailableReason {
                Text(reason)
                    .foregroundStyle(.secondary)
            }

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
                    if let previewImage = selectedPreviewImage {
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
                case .qr:
                    qrInspector
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

    private var qrInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: selectedQRCodeTextBinding)
                .frame(minHeight: 96)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.35))
                }

            Picker("Error correction", selection: selectedQRCodeErrorCorrectionBinding) {
                ForEach(QRCodeErrorCorrection.allCases) { correction in
                    Text(correction.title).tag(correction)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var textInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: selectedTextBinding)
                .frame(minHeight: 96)
                .focused($isTextInspectorFocused)
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
            .onTapGesture(count: 2) {
                selectedElementID = element.id
                if case .text = element {
                    focusTextInspector()
                }
            }
            .onTapGesture(count: 1) {
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

        case .qr(let qrElement):
            if let qrImage = QRCodeRenderer.makeImage(from: qrElement) {
                Image(decorative: qrImage, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .background(Color.white)
            } else {
                Color.white
                    .overlay {
                        Image(systemName: "qrcode")
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
                schedulePreviewRefresh()
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
                schedulePreviewRefresh()
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

    private var selectedQRCodeElement: QRCodeElement? {
        guard case .qr(let element) = selectedElement else {
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

    private var selectedQRCodeTextBinding: Binding<String> {
        Binding(
            get: { selectedQRCodeElement?.text ?? "" },
            set: { text in
                updateSelectedQRCode { qrElement in
                    qrElement.text = text
                }
            }
        )
    }

    private var selectedQRCodeErrorCorrectionBinding: Binding<QRCodeErrorCorrection> {
        Binding(
            get: { selectedQRCodeElement?.errorCorrection ?? .m },
            set: { correction in
                updateSelectedQRCode { qrElement in
                    qrElement.errorCorrection = correction
                }
            }
        )
    }

    private func addImage(from item: PhotosPickerItem?) async {
        logger.log(.image, "PhotosPicker result", metadata: ["hasItem": item != nil])

        guard let item else {
            return
        }

        let data: Data
        do {
            guard let loadedData = try await item.loadTransferable(type: Data.self) else {
                await MainActor.run {
                    statusMessage = "Image load failed"
                    logger.log(.error, "PhotosPicker returned no data")
                }
                return
            }
            data = loadedData
        } catch {
            await MainActor.run {
                statusMessage = "Image load failed: \(error.localizedDescription)"
                logger.log(.error, "PhotosPicker load failed", metadata: ["error": error.localizedDescription])
            }
            return
        }

        await MainActor.run {
            logger.log(.image, "PhotosPicker data loaded", metadata: ["bytes": data.count])
            if let image = UIImage(data: data) {
                logger.log(
                    .image,
                    "PhotosPicker decode success",
                    metadata: [
                        "sourceDimensions": "\(Int(image.size.width * image.scale))x\(Int(image.size.height * image.scale))",
                        "orientation": "\(image.imageOrientation.rawValue)"
                    ]
                )
            } else {
                logger.log(.error, "PhotosPicker decode failed")
                statusMessage = "Image decode failed"
                photoSelection = nil
                return
            }

            let elementID = document.addImageElement(imageData: data)
            selectedElementID = elementID
            photoSelection = nil
            logger.log(.editor, "image element added", metadata: ["element": elementID.uuidString])
            saveDocument()
            schedulePreviewRefresh()
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

    private func updateSelectedQRCode(_ update: (inout QRCodeElement) -> Void) {
        guard let selectedElementID else {
            return
        }

        updateElement(id: selectedElementID) { element in
            guard case .qr(var qrElement) = element else {
                return
            }

            update(&qrElement)
            element = .qr(qrElement)
        }
    }

    private func updateElement(id: UUID, persist: Bool = true, update: (inout PrintElement) -> Void) {
        document.updateElement(id: id, update: update)

        if persist {
            saveDocument()
            schedulePreviewRefresh()
        }
    }

    private func duplicateSelectedElement() {
        guard let selectedElementID,
              let duplicateID = document.duplicateElement(id: selectedElementID) else {
            return
        }

        self.selectedElementID = duplicateID
        saveDocument()
        schedulePreviewRefresh()
    }

    private func deleteSelectedElement() {
        guard let selectedElementID else {
            return
        }

        document.deleteElement(id: selectedElementID)
        self.selectedElementID = nil
        saveDocument()
        schedulePreviewRefresh()
    }

    private func frame(for elementID: UUID) -> PrintElementFrame? {
        document.firstPage.elements.first { $0.id == elementID }?.frame
    }

    private func refreshPreview() {
        let documentSnapshot = document
        let preferencesSnapshot = preferencesStore.preferences
        previewDebouncer.performImmediately {
            buildPreview(document: documentSnapshot, preferences: preferencesSnapshot)
        }
    }

    private func schedulePreviewRefresh() {
        let documentSnapshot = document
        let preferencesSnapshot = preferencesStore.preferences
        previewDebouncer.schedule {
            buildPreview(document: documentSnapshot, preferences: preferencesSnapshot)
        }
    }

    private func buildPreview(document: PrintDocument, preferences: PrintingPreferences) {
        do {
            latestPreview = try jobBuilder.makePreview(
                document: document,
                preferences: preferences
            )
            if statusMessage?.hasPrefix("Render failed") == true {
                statusMessage = nil
            }
        } catch {
            latestPreview = nil
            statusMessage = "Render failed: \(error.localizedDescription)"
            logger.log(.error, "preview failed", metadata: ["error": error.localizedDescription])
        }
    }

    private func saveDocument() {
        documentStore.save(document)
    }

    private func printCurrentDocument() {
        dismissEditorKeyboard()
        logger.log(
            .app,
            "Print button tapped",
            metadata: [
                "document": document.id.uuidString,
                "elements": document.firstPage.elements.count
            ]
        )

        if let reason = printUnavailableReason {
            statusMessage = reason
            logger.log(.editor, "print unavailable", metadata: ["reason": reason])
            return
        }

        documentStore.save(document)
        previewDebouncer.cancel()

        do {
            statusMessage = "Rendering..."
            let preview = try jobBuilder.makePreview(
                document: document,
                preferences: preferencesStore.preferences
            )
            latestPreview = preview

            let job = try jobBuilder.makeJob(
                document: document,
                preview: preview,
                preferences: preferencesStore.preferences
            )
            if printQueue.enqueueIfIdle(job, printer: MX10Printer(bluetoothManager: bluetoothManager)) {
                statusMessage = "Queued \(job.rows.count) rows"
            } else {
                statusMessage = "Another print job is active"
            }
        } catch {
            statusMessage = "Render failed: \(error.localizedDescription)"
            logger.log(.error, "print job build failed", metadata: ["error": error.localizedDescription])
        }
    }

    private func focusTextInspector() {
        DispatchQueue.main.async {
            isTextInspectorFocused = true
        }
    }

    private var selectedPreviewImage: CGImage? {
        if preferencesStore.preferences.showFinalRasterPreview {
            return latestPreview?.previewImage
        }

        return latestPreview?.renderedImage
    }

    private var printUnavailableReason: String? {
        if printQueue.hasActiveOrPendingJob {
            return "Another print job is active"
        }

        if document.firstPage.elements.isEmpty {
            return "Document is empty"
        }

        if !bluetoothManager.isConnected {
            return "Printer disconnected"
        }

        if !bluetoothManager.canSendPrintData {
            return "Printer not ready"
        }

        if latestPreview == nil {
            return "Render failed"
        }

        return nil
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
