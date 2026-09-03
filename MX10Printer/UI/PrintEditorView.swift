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
    @State private var isStickerPickerPresented = false
    @State private var isFramePickerPresented = false
    @State private var isDrawingMode = false
    @State private var drawingTool: DraftDrawingTool = .pen
    @State private var drawingLineWidth: DrawingPenWidth = .medium
    @State private var draftDrawingStrokes: [DrawingStroke] = []
    @State private var activeDraftStroke: DrawingStroke?

    private let logger = DiagnosticLogger.shared
    private let jobBuilder = PrintJobBuilder()
    private let canvasMargin: CGFloat = 12

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
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    editorHeader
                    editorCanvasArea
                    bottomDock
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(Color(.systemGroupedBackground))
            }
            .navigationTitle("Print Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveDocument()
                        dismiss()
                    }
                    .disabled(isDrawingMode)
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
        .onChange(of: bluetoothManager.printerStateText) { _, newValue in
            guard printQueue.isPrinting, newValue == "Disconnected" else {
                return
            }

            printQueue.failCurrentJob(reason: "Printer disconnected")
        }
        .sheet(isPresented: $isStickerPickerPresented) {
            StickerPickerSheet(
                onSelect: addSticker(kind:),
                onClose: {
                    isStickerPickerPresented = false
                }
            )
        }
        .sheet(isPresented: $isFramePickerPresented) {
            FramePickerSheet(
                onSelect: addFrame(kind:),
                onClose: {
                    isFramePickerPresented = false
                }
            )
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 10) {
            TextField("Document title", text: titleBinding)
                .textFieldStyle(.roundedBorder)
                .font(.headline)

            Button {
                isPreviewMode.toggle()
                refreshPreview()
            } label: {
                Label(isPreviewMode ? "Edit" : "Preview", systemImage: isPreviewMode ? "rectangle.and.pencil.and.ellipsis" : "eye")
            }
            .buttonStyle(.bordered)
            .lineLimit(1)
            .disabled(isDrawingMode)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func dismissEditorKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private var editorCanvasArea: some View {
        ZStack(alignment: .bottom) {
            fittedCanvas

            if isDrawingMode {
                drawingPalette
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let selectedElement {
                inspectorPanel(for: selectedElement)
                    .padding(.horizontal, 12)
                    .padding(.bottom, statusBannerMessage == nil ? 10 : 58)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            statusBanner
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemBackground))
    }

    private var statusBannerMessage: String? {
        if printQueue.isPrinting {
            return "Printing..."
        }

        if isDrawingMode {
            return nil
        }

        if let failure = printQueue.failedJobs.last {
            return "Last failure: \(failure.message)"
        }

        if let statusMessage {
            return statusMessage
        }

        return printUnavailableReason
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let message = statusBannerMessage {
            VStack(alignment: .leading, spacing: 5) {
                Text(message)
                    .font(.subheadline.weight(printQueue.isPrinting ? .semibold : .regular))
                    .foregroundStyle(statusMessageColor)

                if printQueue.isPrinting {
                    ProgressView(value: printQueue.progressFraction)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Color.black.opacity(0.08), radius: 8, y: 2)
        }
    }

    private var statusMessageColor: Color {
        if printQueue.failedJobs.last != nil {
            return .red
        }

        return .secondary
    }

    private var fittedCanvas: some View {
        GeometryReader { geometry in
            let availableSize = CGSize(
                width: max(0, geometry.size.width - canvasMargin * 2),
                height: max(0, geometry.size.height - canvasMargin * 2)
            )
            let layout = EditorCanvasLayout(pageSize: pageSize, availableSize: availableSize)

            ZStack {
                if layout.scale > 0 {
                    pageCanvas(canvasScale: layout.scale)
                        .frame(width: layout.displaySize.width, height: layout.displaySize.height, alignment: .topLeading)
                        .clipped()
                } else {
                    Text("Preview unavailable")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(canvasMargin)
        }
    }

    private var pageSize: CGSize {
        CGSize(
            width: CGFloat(PrintDocument.pageWidth),
            height: CGFloat(document.firstPage.height)
        )
    }

    private func pageCanvas(canvasScale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Color.white

                if isPreviewMode {
                    if let previewImage = selectedPreviewImage {
                        Image(decorative: previewImage, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: pageSize.width, height: pageSize.height)
                    } else {
                        Text("Preview unavailable")
                            .foregroundStyle(.secondary)
                            .frame(width: pageSize.width, height: pageSize.height)
                    }
                } else {
                    ForEach(document.firstPage.elements) { element in
                        elementLayer(element, canvasScale: canvasScale)
                            .allowsHitTesting(!isDrawingMode)
                    }
                }
            }
            .frame(width: pageSize.width, height: pageSize.height)
            .scaleEffect(canvasScale, anchor: .topLeading)
            .frame(
                width: pageSize.width * canvasScale,
                height: pageSize.height * canvasScale,
                alignment: .topLeading
            )

            if isDrawingMode {
                DraftDrawingView(strokes: draftStrokesForDisplay, scale: canvasScale)
                    .frame(width: pageSize.width * canvasScale, height: pageSize.height * canvasScale)
                    .allowsHitTesting(false)

                DrawingInputSurface(
                    onChanged: { displayPoint in
                        handleDrawingDragChanged(displayPoint: displayPoint, canvasScale: canvasScale)
                    },
                    onEnded: { displayPoint in
                        handleDrawingDragEnded(displayPoint: displayPoint, canvasScale: canvasScale)
                    }
                )
                .frame(width: pageSize.width * canvasScale, height: pageSize.height * canvasScale)
            }
        }
        .frame(width: pageSize.width * canvasScale, height: pageSize.height * canvasScale)
        .background(Color.white)
        .overlay {
            Rectangle()
                .stroke(Color.secondary, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isDrawingMode {
                selectedElementID = nil
                dismissEditorKeyboard()
            }
        }
    }

    private var bottomDock: some View {
        HStack(spacing: 8) {
            Button {
                addText()
            } label: {
                DockToolLabel(title: "Text", systemImageName: "textformat")
            }
            .buttonStyle(.plain)
            .disabled(isDrawingMode)

            PhotosPicker(selection: $photoSelection, matching: .images) {
                DockToolLabel(title: "Image", systemImageName: "photo")
            }
            .buttonStyle(.plain)
            .disabled(isDrawingMode)

            Button {
                isStickerPickerPresented = true
            } label: {
                DockToolLabel(title: "Sticker", systemImageName: "face.smiling")
            }
            .buttonStyle(.plain)
            .disabled(isDrawingMode)

            Button {
                isFramePickerPresented = true
            } label: {
                DockToolLabel(title: "Frame", systemImageName: "rectangle")
            }
            .buttonStyle(.plain)
            .disabled(isDrawingMode)

            Button {
                enterDrawingMode()
            } label: {
                DockToolLabel(title: "Draw", systemImageName: "pencil.tip")
            }
            .buttonStyle(.plain)
            .disabled(isDrawingMode)

            if printQueue.isPrinting {
                Button(role: .destructive) {
                    dismissEditorKeyboard()
                    printQueue.cancelCurrentJob()
                } label: {
                    DockToolLabel(title: "Cancel", systemImageName: "xmark.circle.fill", isProminent: true, isDestructive: true)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    printCurrentDocument()
                } label: {
                    DockToolLabel(title: "Print", systemImageName: "printer.fill", isProminent: true)
                }
                .buttonStyle(.plain)
                .disabled(printUnavailableReason != nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var drawingPalette: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Pen width", selection: $drawingLineWidth) {
                ForEach(DrawingPenWidth.allCases) { width in
                    Text(width.title).tag(width)
                }
            }
            .pickerStyle(.segmented)
            .disabled(drawingTool == .eraser)

            HStack(spacing: 8) {
                DrawingPaletteButton(
                    title: "Pen",
                    systemImageName: "pencil.tip",
                    isSelected: drawingTool == .pen
                ) {
                    drawingTool = .pen
                }

                DrawingPaletteButton(
                    title: "Eraser",
                    systemImageName: "eraser",
                    isSelected: drawingTool == .eraser
                ) {
                    activeDraftStroke = nil
                    drawingTool = .eraser
                }

                DrawingPaletteButton(
                    title: "Undo",
                    systemImageName: "arrow.uturn.backward",
                    isEnabled: !draftDrawingStrokes.isEmpty
                ) {
                    undoDrawingStroke()
                }

                DrawingPaletteButton(
                    title: "Clear",
                    systemImageName: "trash",
                    isEnabled: !draftDrawingStrokes.isEmpty || activeDraftStroke != nil,
                    isDestructive: true
                ) {
                    clearDraftDrawing()
                }

                DrawingPaletteButton(
                    title: "Cancel",
                    systemImageName: "xmark",
                    isSubtle: true
                ) {
                    cancelDrawing()
                }

                DrawingPaletteButton(
                    title: "Done",
                    systemImageName: "checkmark",
                    isProminent: true
                ) {
                    commitDrawing()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 14, y: 4)
    }

    private func inspectorPanel(for selectedElement: PrintElement) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(elementTitle(for: selectedElement), systemImage: elementIconName(for: selectedElement))
                    .font(.headline)

                Spacer()

                Button {
                    selectedElementID = nil
                    dismissEditorKeyboard()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close inspector")
            }

            ScrollView(.vertical, showsIndicators: false) {
                inspectorControls(for: selectedElement)
                    .padding(.bottom, 2)
            }
            .frame(maxHeight: 178)

            HStack {
                Button {
                    duplicateSelectedElement()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }

                Spacer()

                Button(role: .destructive) {
                    deleteSelectedElement()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: 280, alignment: .top)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 14, y: 4)
    }

    @ViewBuilder
    private func inspectorControls(for selectedElement: PrintElement) -> some View {
        switch selectedElement {
        case .text:
            textInspector
        case .image:
            imageInspector
        case .sticker:
            stickerInspector
        case .frame:
            frameInspector
        case .drawing:
            drawingInspector
        }
    }

    private func elementTitle(for element: PrintElement) -> String {
        switch element {
        case .text:
            return "Text"
        case .image:
            return "Image"
        case .sticker:
            return "Sticker"
        case .frame:
            return "Frame"
        case .drawing:
            return "Drawing"
        }
    }

    private func elementIconName(for element: PrintElement) -> String {
        switch element {
        case .text:
            return "textformat"
        case .image:
            return "photo"
        case .sticker:
            return "face.smiling"
        case .frame:
            return "rectangle"
        case .drawing:
            return "pencil.line"
        }
    }

    private var textInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Text", text: selectedTextBinding)
                .textFieldStyle(.roundedBorder)

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

            LazyVGrid(columns: inspectorButtonColumns, spacing: 8) {
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

    private var stickerInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: stickerInspectorColumns, spacing: 6) {
                ForEach(StickerKind.allCases) { kind in
                    CompactStickerKindButton(
                        kind: kind,
                        isSelected: selectedStickerElement?.kind == kind
                    ) {
                        updateSelectedSticker { stickerElement in
                            stickerElement.kind = kind
                        }
                    }
                }
            }

            Button {
                updateSelectedSticker { stickerElement in
                    stickerElement.rotationDegrees = (stickerElement.rotationDegrees + 90).truncatingRemainder(dividingBy: 360)
                }
            } label: {
                Label("Rotate 90", systemImage: "rotate.right")
            }
            .buttonStyle(.bordered)
        }
    }

    private var frameInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: frameInspectorColumns, spacing: 6) {
                ForEach(FrameKind.allCases) { kind in
                    CompactFrameKindButton(
                        kind: kind,
                        lineWidth: selectedFrameElement?.lineWidth ?? 3,
                        isSelected: selectedFrameElement?.kind == kind
                    ) {
                        updateSelectedFrame { frameElement in
                            frameElement.kind = kind
                        }
                    }
                }
            }

            VStack(alignment: .leading) {
                Text("Thickness: \(Int(selectedFrameElement?.lineWidth ?? 3))")
                Slider(value: selectedFrameLineWidthBinding, in: 1...8, step: 1)
            }

            Button {
                updateSelectedFrame { frameElement in
                    frameElement.rotationDegrees = (frameElement.rotationDegrees + 90).truncatingRemainder(dividingBy: 360)
                }
            } label: {
                Label("Rotate 90", systemImage: "rotate.right")
            }
            .buttonStyle(.bordered)
        }
    }

    private var drawingInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drawing")
                .font(.subheadline.weight(.semibold))

            Text("\(selectedDrawingElement?.strokes.count ?? 0) strokes")
                .foregroundStyle(.secondary)

            Button {
                updateSelectedDrawing { drawingElement in
                    drawingElement.rotationDegrees = (drawingElement.rotationDegrees + 90).truncatingRemainder(dividingBy: 360)
                }
            } label: {
                Label("Rotate 90", systemImage: "rotate.right")
            }
            .buttonStyle(.bordered)
        }
    }

    private var inspectorButtonColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ]
    }

    private var stickerInspectorColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: 6)
    }

    private var frameInspectorColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: 5)
    }


    @ViewBuilder
    private func elementLayer(_ element: PrintElement, canvasScale: CGFloat) -> some View {
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
                        .frame(width: 26, height: 26)
                        .gesture(resizeGesture(for: element.id, canvasScale: canvasScale))
                }
            }
            .rotationEffect(.degrees(element.rotationDegrees))
            .position(
                x: CGFloat(frame.x + frame.width / 2),
                y: CGFloat(frame.y + frame.height / 2)
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 1) {
                selectedElementID = element.id
            }
            .gesture(moveGesture(for: element.id, canvasScale: canvasScale))
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

        case .sticker(let stickerElement):
            if let stickerImage = StickerRenderer.image(
                for: stickerElement.kind,
                pointSize: CGFloat(max(stickerElement.frame.width, stickerElement.frame.height))
            ) {
                Image(uiImage: stickerImage)
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                Image(systemName: "questionmark")
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

        case .frame(let frameElement):
            FrameElementView(element: frameElement)
        case .drawing(let drawingElement):
            DrawingElementView(element: drawingElement)
        }
    }

    private func moveGesture(for elementID: UUID, canvasScale: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if moveStartFrames[elementID] == nil {
                    moveStartFrames[elementID] = frame(for: elementID)
                    selectedElementID = elementID
                }

                guard let startFrame = moveStartFrames[elementID] else {
                    return
                }

                let documentTranslation = EditorCanvasLayout.documentTranslation(
                    displayTranslation: value.translation,
                    scale: canvasScale
                )
                let updatedFrame = startFrame.offsetBy(
                    dx: Double(documentTranslation.width),
                    dy: Double(documentTranslation.height)
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

    private func resizeGesture(for elementID: UUID, canvasScale: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if resizeStartFrames[elementID] == nil {
                    resizeStartFrames[elementID] = frame(for: elementID)
                    selectedElementID = elementID
                }

                guard let startFrame = resizeStartFrames[elementID] else {
                    return
                }

                let documentTranslation = EditorCanvasLayout.documentTranslation(
                    displayTranslation: value.translation,
                    scale: canvasScale
                )
                let updatedFrame = startFrame.resizedBy(
                    dw: Double(documentTranslation.width),
                    dh: Double(documentTranslation.height)
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

    private var selectedStickerElement: StickerElement? {
        guard case .sticker(let element) = selectedElement else {
            return nil
        }

        return element
    }

    private var selectedFrameElement: FrameElement? {
        guard case .frame(let element) = selectedElement else {
            return nil
        }

        return element
    }

    private var selectedDrawingElement: DrawingElement? {
        guard case .drawing(let element) = selectedElement else {
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

    private var selectedFrameLineWidthBinding: Binding<Double> {
        Binding(
            get: { selectedFrameElement?.lineWidth ?? 3 },
            set: { lineWidth in
                updateSelectedFrame { frameElement in
                    frameElement.lineWidth = lineWidth.rounded()
                }
            }
        )
    }

    private func addText() {
        let elementID = document.addTextElement()
        selectedElementID = elementID
        logger.log(.editor, "text element added", metadata: ["element": elementID.uuidString])
        saveDocument()
        refreshPreview()
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
            refreshPreview()
        }
    }

    private func addSticker(kind: StickerKind) {
        let elementID = document.addStickerElement(kind: kind)
        selectedElementID = elementID
        saveDocument()
        refreshPreview()
        isStickerPickerPresented = false
        logger.log(
            .editor,
            "sticker element added",
            metadata: [
                "element": elementID.uuidString,
                "kind": kind.rawValue
            ]
        )
    }

    private func addFrame(kind: FrameKind) {
        let elementID = document.addFrameElement(kind: kind)
        selectedElementID = elementID
        saveDocument()
        refreshPreview()
        isFramePickerPresented = false
        logger.log(
            .editor,
            "frame element added",
            metadata: [
                "element": elementID.uuidString,
                "kind": kind.rawValue
            ]
        )
    }

    private func enterDrawingMode() {
        dismissEditorKeyboard()
        selectedElementID = nil
        isPreviewMode = false
        drawingTool = .pen
        drawingLineWidth = .medium
        draftDrawingStrokes = []
        activeDraftStroke = nil
        statusMessage = nil
        isDrawingMode = true
        logger.log(.editor, "draw mode entered")
    }

    private var draftStrokesForDisplay: [DrawingStroke] {
        if let activeDraftStroke {
            return draftDrawingStrokes + [activeDraftStroke]
        }

        return draftDrawingStrokes
    }

    private func handleDrawingDragChanged(displayPoint: CGPoint, canvasScale: CGFloat) {
        guard let documentPoint = drawingPoint(displayPoint: displayPoint, canvasScale: canvasScale) else {
            return
        }

        switch drawingTool {
        case .pen:
            if let activeDraftStroke {
                self.activeDraftStroke = DrawingGeometry.sampledStroke(from: activeDraftStroke, adding: documentPoint)
            } else {
                activeDraftStroke = DrawingStroke(points: [documentPoint], lineWidth: drawingLineWidth.lineWidth)
            }
        case .eraser:
            eraseDraftStroke(at: documentPoint)
        }
    }

    private func handleDrawingDragEnded(displayPoint: CGPoint, canvasScale: CGFloat) {
        guard drawingTool == .pen else {
            return
        }

        if let documentPoint = drawingPoint(displayPoint: displayPoint, canvasScale: canvasScale),
           let activeDraftStroke {
            self.activeDraftStroke = DrawingGeometry.sampledStroke(from: activeDraftStroke, adding: documentPoint)
        }

        completeActiveDraftStroke()
    }

    private func drawingPoint(displayPoint: CGPoint, canvasScale: CGFloat) -> DrawingPoint? {
        let displaySize = EditorCanvasLayout.displaySize(pageSize: pageSize, scale: canvasScale)
        guard displayPoint.x.isFinite,
              displayPoint.y.isFinite,
              displayPoint.x >= 0,
              displayPoint.y >= 0,
              displayPoint.x <= displaySize.width,
              displayPoint.y <= displaySize.height else {
            return nil
        }

        let documentPoint = EditorCanvasLayout.documentPoint(
            displayPoint: displayPoint,
            scale: canvasScale,
            pageSize: pageSize
        )
        return DrawingPoint(x: Double(documentPoint.x), y: Double(documentPoint.y))
    }

    private func completeActiveDraftStroke() {
        guard let activeDraftStroke,
              !activeDraftStroke.points.isEmpty else {
            self.activeDraftStroke = nil
            return
        }

        draftDrawingStrokes.append(activeDraftStroke)
        self.activeDraftStroke = nil
        logger.log(
            .editor,
            "drawing stroke completed",
            metadata: [
                "points": activeDraftStroke.points.count,
                "lineWidth": activeDraftStroke.lineWidth
            ]
        )
    }

    private func eraseDraftStroke(at point: DrawingPoint) {
        let before = draftDrawingStrokes.count
        draftDrawingStrokes.removeAll { stroke in
            DrawingGeometry.stroke(stroke, contains: point)
        }
        let removed = before - draftDrawingStrokes.count

        if removed > 0 {
            logger.log(.editor, "drawing stroke erased", metadata: ["removed": removed])
        }
    }

    private func undoDrawingStroke() {
        guard !draftDrawingStrokes.isEmpty else {
            return
        }

        let removed = draftDrawingStrokes.removeLast()
        logger.log(
            .editor,
            "drawing stroke undone",
            metadata: [
                "stroke": removed.id.uuidString,
                "remaining": draftDrawingStrokes.count
            ]
        )
    }

    private func clearDraftDrawing() {
        let removed = draftDrawingStrokes.count + (activeDraftStroke == nil ? 0 : 1)
        guard removed > 0 else {
            return
        }

        draftDrawingStrokes = []
        activeDraftStroke = nil
        logger.log(.editor, "drawing cleared", metadata: ["removed": removed])
    }

    private func cancelDrawing() {
        let discardedStrokes = draftDrawingStrokes.count + (activeDraftStroke == nil ? 0 : 1)
        draftDrawingStrokes = []
        activeDraftStroke = nil
        isDrawingMode = false
        drawingTool = .pen
        logger.log(.editor, "drawing cancelled", metadata: ["strokes": discardedStrokes])
    }

    private func commitDrawing() {
        completeActiveDraftStroke()

        guard let drawing = DrawingGeometry.drawingElement(
            from: draftDrawingStrokes,
            pageWidth: PrintDocument.pageWidth,
            pageHeight: document.firstPage.height
        ) else {
            draftDrawingStrokes = []
            isDrawingMode = false
            drawingTool = .pen
            return
        }

        let elementID = document.addDrawingElement(drawing)
        selectedElementID = elementID
        draftDrawingStrokes = []
        activeDraftStroke = nil
        isDrawingMode = false
        drawingTool = .pen
        saveDocument()
        refreshPreview()
        logger.log(
            .editor,
            "drawing element added",
            metadata: [
                "element": elementID.uuidString,
                "strokes": drawing.strokes.count,
                "points": DrawingGeometry.totalPointCount(in: drawing.strokes),
                "frame": "x:\(Int(drawing.frame.x)),y:\(Int(drawing.frame.y)),w:\(Int(drawing.frame.width)),h:\(Int(drawing.frame.height))"
            ]
        )
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

    private func updateSelectedSticker(_ update: (inout StickerElement) -> Void) {
        guard let selectedElementID else {
            return
        }

        updateElement(id: selectedElementID) { element in
            guard case .sticker(var stickerElement) = element else {
                return
            }

            update(&stickerElement)
            element = .sticker(stickerElement)
        }
    }

    private func updateSelectedFrame(_ update: (inout FrameElement) -> Void) {
        guard let selectedElementID else {
            return
        }

        updateElement(id: selectedElementID) { element in
            guard case .frame(var frameElement) = element else {
                return
            }

            update(&frameElement)
            element = .frame(frameElement)
        }
    }

    private func updateSelectedDrawing(_ update: (inout DrawingElement) -> Void) {
        guard let selectedElementID else {
            return
        }

        updateElement(id: selectedElementID) { element in
            guard case .drawing(var drawingElement) = element else {
                return
            }

            update(&drawingElement)
            element = .drawing(drawingElement)
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
        do {
            latestPreview = try jobBuilder.makePreview(
                document: document,
                preferences: preferencesStore.preferences
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

        do {
            statusMessage = "Rendering..."
            let preview = try jobBuilder.makePreview(
                document: document,
                preferences: preferencesStore.preferences
            )
            latestPreview = preview

            let job = jobBuilder.makeJob(
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

    private var selectedPreviewImage: CGImage? {
        if preferencesStore.preferences.showFinalRasterPreview {
            return latestPreview?.previewImage
        }

        return latestPreview?.renderedImage
    }

    private var printUnavailableReason: String? {
        if isDrawingMode {
            return "Finish drawing first"
        }

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

private enum DraftDrawingTool {
    case pen
    case eraser
}

private struct DrawingInputSurface: View {
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onChanged(value.location)
                    }
                    .onEnded { value in
                        onEnded(value.location)
                    }
            )
            .accessibilityLabel("Drawing surface")
    }
}

private struct DraftDrawingView: View {
    let strokes: [DrawingStroke]
    let scale: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(strokes) { stroke in
                DrawingStrokeView(stroke: stroke, scaleX: scale, scaleY: scale)
            }
        }
    }
}

private struct DrawingElementView: View {
    let element: DrawingElement

    var body: some View {
        GeometryReader { geometry in
            if element.sourceSize.width > 0,
               element.sourceSize.height > 0,
               geometry.size.width > 0,
               geometry.size.height > 0 {
                let scaleX = geometry.size.width / CGFloat(element.sourceSize.width)
                let scaleY = geometry.size.height / CGFloat(element.sourceSize.height)

                ZStack(alignment: .topLeading) {
                    ForEach(element.strokes) { stroke in
                        DrawingStrokeView(stroke: stroke, scaleX: scaleX, scaleY: scaleY)
                    }
                }
            }
        }
    }
}

private struct DrawingStrokeView: View {
    let stroke: DrawingStroke
    let scaleX: CGFloat
    let scaleY: CGFloat

    var body: some View {
        let points = stroke.points.filter(\.isFinite)
        let lineWidth = DrawingRenderer.clampedLineWidth(stroke.lineWidth * Double(min(scaleX, scaleY)))

        if let firstPoint = points.first {
            if points.count == 1 {
                Circle()
                    .fill(Color.black)
                    .frame(width: lineWidth, height: lineWidth)
                    .position(x: CGFloat(firstPoint.x) * scaleX, y: CGFloat(firstPoint.y) * scaleY)
            } else {
                Path { path in
                    path.move(to: CGPoint(x: CGFloat(firstPoint.x) * scaleX, y: CGFloat(firstPoint.y) * scaleY))
                    for point in points.dropFirst() {
                        path.addLine(to: CGPoint(x: CGFloat(point.x) * scaleX, y: CGFloat(point.y) * scaleY))
                    }
                }
                .stroke(
                    Color.black,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }
}

private struct DrawingPaletteButton: View {
    let title: String
    let systemImageName: String
    var isSelected = false
    var isEnabled = true
    var isProminent = false
    var isDestructive = false
    var isSubtle = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImageName)
                    .font(.system(size: 17, weight: .semibold))

                Text(title)
                    .font(.caption2.weight(isProminent ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(foregroundColor)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(borderColor, lineWidth: isSelected ? 2 : 1)
            }
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }

    private var foregroundColor: Color {
        if isProminent {
            return .white
        }

        if isDestructive {
            return .red
        }

        return .primary
    }

    private var background: Color {
        if isProminent {
            return .accentColor
        }

        if isSelected {
            return Color.accentColor.opacity(0.16)
        }

        return isSubtle ? Color.clear : Color(.secondarySystemBackground)
    }

    private var borderColor: Color {
        if isSelected {
            return .accentColor
        }

        return Color.secondary.opacity(isSubtle ? 0.18 : 0.3)
    }
}

private struct DockToolLabel: View {
    @Environment(\.isEnabled) private var isEnabled

    let title: String
    let systemImageName: String
    var isProminent = false
    var isDestructive = false

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemImageName)
                .font(.system(size: isProminent ? 21 : 19, weight: .semibold))

            Text(title)
                .font(.caption2.weight(isProminent ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 54)
        .foregroundStyle(foregroundColor)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(borderColor, lineWidth: isProminent ? 0 : 1)
        }
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(title)
    }

    private var foregroundColor: Color {
        isProminent ? .white : .primary
    }

    private var background: Color {
        if isProminent {
            return isDestructive ? .red : .accentColor
        }

        return Color(.secondarySystemBackground)
    }

    private var borderColor: Color {
        Color.secondary.opacity(0.3)
    }
}

private struct CompactStickerKindButton: View {
    let kind: StickerKind
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            StickerSymbolView(kind: kind, pointSize: 24)
                .padding(6)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(isSelected ? Color.accentColor.opacity(0.16) : Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2 : 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.title)
    }
}

private struct CompactFrameKindButton: View {
    let kind: FrameKind
    let lineWidth: Double
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FrameStylePreview(kind: kind, lineWidth: lineWidth)
                .padding(5)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(isSelected ? Color.accentColor.opacity(0.16) : Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2 : 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.title)
    }
}

private struct FramePickerSheet: View {
    let onSelect: (FrameKind) -> Void
    let onClose: () -> Void

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 12),
        count: 3
    )

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(FrameKind.allCases) { kind in
                        FrameKindButton(kind: kind, lineWidth: 3, isSelected: false) {
                            onSelect(kind)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
            .navigationTitle("Frame")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        onClose()
                    }
                }
            }
        }
    }
}

private struct FrameKindButton: View {
    let kind: FrameKind
    let lineWidth: Double
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                FrameStylePreview(kind: kind, lineWidth: lineWidth)
                    .frame(width: 64, height: 44)

                Text(kind.title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 96, height: 82)
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color(.secondarySystemBackground))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.title)
    }
}

private struct FrameElementView: View {
    let element: FrameElement

    var body: some View {
        FrameStylePreview(kind: element.kind, lineWidth: element.lineWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FrameStylePreview: View {
    let kind: FrameKind
    let lineWidth: Double

    var body: some View {
        GeometryReader { geometry in
            style(in: geometry.size)
        }
    }

    @ViewBuilder
    private func style(in size: CGSize) -> some View {
        let strokeWidth = FrameRenderer.clampedLineWidth(lineWidth)
        let strokeStyle = StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
        let dashedStyle = StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round, dash: [8, 6])
        let cornerRadius = min(CGFloat(18), min(size.width, size.height) * 0.15)

        switch kind {
        case .rounded:
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.black, style: strokeStyle)
        case .square:
            Rectangle()
                .strokeBorder(Color.black, style: strokeStyle)
        case .dashed:
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.black, style: dashedStyle)
        case .double:
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.black, style: strokeStyle)

                if canDrawInnerOutline(in: size, strokeWidth: strokeWidth) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.black, style: strokeStyle)
                        .padding(innerOutlineInset(for: strokeWidth))
                }
            }
        case .oval:
            Ellipse()
                .strokeBorder(Color.black, style: strokeStyle)
        }
    }

    private func innerOutlineInset(for strokeWidth: CGFloat) -> CGFloat {
        max(CGFloat(6), strokeWidth * 2.5)
    }

    private func canDrawInnerOutline(in size: CGSize, strokeWidth: CGFloat) -> Bool {
        let inset = innerOutlineInset(for: strokeWidth)
        return size.width > inset * 2 + strokeWidth * 2
            && size.height > inset * 2 + strokeWidth * 2
    }
}

private struct StickerPickerSheet: View {
    let onSelect: (StickerKind) -> Void
    let onClose: () -> Void

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 12),
        count: 3
    )

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(StickerKind.allCases) { kind in
                        StickerKindButton(kind: kind, isSelected: false) {
                            onSelect(kind)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
            .navigationTitle("Sticker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        onClose()
                    }
                }
            }
        }
    }
}

private struct StickerKindButton: View {
    let kind: StickerKind
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                StickerSymbolView(kind: kind, pointSize: 44)
                    .frame(width: 54, height: 48)

                Text(kind.title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 86, height: 82)
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color(.secondarySystemBackground))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.title)
    }
}

private struct StickerSymbolView: View {
    let kind: StickerKind
    let pointSize: CGFloat

    var body: some View {
        if let image = StickerRenderer.image(for: kind, pointSize: pointSize) {
            Image(uiImage: image)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "questionmark")
                .foregroundStyle(.black)
        }
    }
}
