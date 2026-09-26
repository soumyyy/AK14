import Analysis
import Core
import Director
import Photos
import PhotosUI
import Render
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class ImportReviewModel {
    struct AlertMessage: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    enum State: Equatable {
        case idle, requestingAccess, loading, importing, ready, failed(String)
    }

    var state: State = .idle
    var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var startDate = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    var endDate = Date.now
    var assets: [PHAsset] = []
    var selectedIDs: Set<String> = []
    var records: [PhotoRecord] = []
    var events: [EventSegment] = []
    var isPreparingOccasions = false
    var occasionSplitResult: OccasionSplitter.Result?
    private var occasionFeatures: [AssetID: PhotoFeatures] = [:]
    private var occasionThumbnailURLs: [AssetID: URL] = [:]
    var selectedEventIndex: Int?
    var storyHint = ""
    var importedFolder: URL?
    var retainedSourceFolders: Set<URL> = []
    var alert: AlertMessage?
    var options: [StoryOption] = []
    var selectedOptionID: String?
    var isGenerating = false
    var isSaving = false
    var isEditingOption = false
    var successfulSaves = 0
    var storyEditors: [URL: StoryEditingService] = [:]
    private var interactionRecorders: [URL: InteractionRecorder] = [:]
    private var presentedRuns: Set<URL> = []
    private var handedOffRuns: Set<URL> = []
    private var abandonedRuns: Set<URL> = []
    var progressMessage = "Preparing…"
    var failureMessage: String?
    private var retryImport = false
    var importCompleted = 0
    var importTotal = 0
    private var importDuration: Double = 0
    var modelAssist = UserDefaults.standard.object(forKey: "ak14.modelAssist") as? Bool ?? true
    var allowThumbnailTransfer = false
    var shareURLs: [URL] = []
    var sharePresented = false
    var showWorkerSettings = false
    var showThumbnailDisclosure = false
    var showLimitedLibraryPicker = false
    var workerBaseURL = UserDefaults.standard.string(forKey: "ak14.workerBaseURL") ?? "https://ak14-api.soumyamaheshwari1234.workers.dev"
    var workerInviteToken = WorkerInviteToken.load() ?? ""
    let injectedClient: ResponsesClient?
    let injectedStylePackProvider: (@Sendable () async throws -> LoadedStylePack)?

    init(client: ResponsesClient? = nil,
         stylePackProvider: (@Sendable () async throws -> LoadedStylePack)? = nil) {
        StoryPipeline.cleanupStaleStaging()
        injectedClient = client
        injectedStylePackProvider = stylePackProvider
    }

    func requestAccessAndLoad() async {
        state = .requestingAccess
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else {
            state = .failed("Photos access is needed to choose images. You can change access in Settings.")
            return
        }
        await loadAssets()
    }

    func loadAssets() async {
        guard authorization == .authorized || authorization == .limited else { return }
        state = .loading
        let exclusiveEnd = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: endDate)) ?? endDate
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@ AND creationDate < %@",
                                        PHAssetMediaType.image.rawValue, Calendar.current.startOfDay(for: startDate) as NSDate, exclusiveEnd as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: options)
        if let importedFolder, !retainedSourceFolders.contains(importedFolder) {
            try? FileManager.default.removeItem(at: importedFolder)
        }
        importedFolder = nil
        assets = (0..<result.count).map { result.object(at: $0) }
        // Keep the user's current choices when the date range or limited library changes.
        // A fresh install starts with nothing selected so importing a large library is deliberate.
        selectedIDs.formIntersection(Set(assets.map(\.localIdentifier)))
        records = []
        events = []
        occasionFeatures = [:]
        occasionThumbnailURLs = [:]
        occasionSplitResult = nil
        self.options = []
        selectedOptionID = nil
        importCompleted = 0
        importTotal = 0
        state = .idle
    }

    func toggle(_ asset: PHAsset) {
        if selectedIDs.contains(asset.localIdentifier) { selectedIDs.remove(asset.localIdentifier) }
        else { selectedIDs.insert(asset.localIdentifier) }
    }

    func importSelection() async -> Bool {
        let chosen = assets.filter { selectedIDs.contains($0.localIdentifier) }
        guard !chosen.isEmpty else { return false }
        state = .importing
        failureMessage = nil
        retryImport = true
        importCompleted = 0
        importTotal = chosen.count
        var destination: URL?
        let importStart = ContinuousClock().now
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "AK14/imports", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let folder = support.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            destination = folder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, asset) in chosen.enumerated() {
                try Task.checkCancellation()
                let photoNumber = index + 1
                let totalPhotos = chosen.count
                progressMessage = "Downloading photo \(index + 1) of \(chosen.count)…"
                try await copyOriginal(asset, to: folder.appending(path: String(format: "photo-%04d.%@", index, fileExtension(asset)))) { fraction in
                    Task { @MainActor in
                        self.progressMessage = String(format: "Downloading photo %d of %d · %d%%", photoNumber, totalPhotos, Int(fraction * 100))
                    }
                }
                importCompleted = index + 1
            }
            try Task.checkCancellation()
            let result = try await FolderIngester().ingest(folder: folder, options: IngestOptions())
            if let old = importedFolder, !retainedSourceFolders.contains(old) {
                try? FileManager.default.removeItem(at: old)
            }
            importedFolder = folder
            importDuration = (ContinuousClock().now - importStart).seconds
            records = result.photos
            events = EventSegmenter.segment(result.photos)
            selectedEventIndex = events.max(by: { $0.photoCount < $1.photoCount })?.index
            await prepareOccasionChoices(useModel: modelAssist)
            storyHint = ""
            options = []
            selectedOptionID = nil
            if result.photos.isEmpty { throw ImportFailure.noReadablePhotos }
            state = .ready
            return true
        } catch is CancellationError {
            if let destination { try? FileManager.default.removeItem(at: destination) }
            state = .idle
            progressMessage = "Preparing…"
            return false
        } catch {
            if let destination { try? FileManager.default.removeItem(at: destination) }
            let failure = ImportFailure.iCloudDownloadFailed(error.localizedDescription)
            failureMessage = failure.localizedDescription
            state = .failed(failure.localizedDescription)
            return false
        }
    }

    func prepareOccasionChoices(useModel: Bool) async {
        guard !records.isEmpty, let folder = importedFolder else { return }
        let client = useModel && allowThumbnailTransfer ? configuredResponsesClient : nil
        let preserveAllEventsChoice = selectedEventIndex == nil
        let previouslySelectedIDs = selectedEventIndex.flatMap { selected in events.first { $0.index == selected }.map { Set($0.assetIDs) } }
        isPreparingOccasions = true
        defer { isPreparingOccasions = false }
        do {
            let support = try StoryPipeline.applicationSupport().appending(path: "analysis-cache", directoryHint: .isDirectory)
            let thumbnailer = Thumbnailer(cacheRoot: support)
            let analyzer = SceneSignatureAnalyzer()
            var thumbnails = occasionThumbnailURLs
            var features = occasionFeatures
            if records.contains(where: { thumbnails[$0.assetID] == nil || features[$0.assetID] == nil }) {
                thumbnails = [:]
                features = [:]
                for (offset, photo) in records.enumerated() {
                    try Task.checkCancellation()
                    let url = try thumbnailer.thumbnail(sha: photo.contentSHA256,
                        source: folder.appending(path: photo.sourceRelativePaths[0]), tier: .analysis)
                    thumbnails[photo.assetID] = url
                    progressMessage = "Preparing occasion previews · \(offset + 1) of \(records.count)"
                    features[photo.assetID] = await analyzer.analyze(photo, thumbnailURL: url)
                }
                occasionThumbnailURLs = thumbnails
                occasionFeatures = features
            }
            let local = EventSegmenter.segment(records, features: features)
            var model: OccasionSplitter.Result?
            if let client { model = await OccasionSplitter.split(events: local, photos: records, thumbnails: thumbnails, features: features, client: client) }
            let acceptedModel = useModel && modelAssist ? model : nil
            occasionSplitResult = acceptedModel
            let next = acceptedModel?.events ?? local
            events = next
            if preserveAllEventsChoice { selectedEventIndex = nil }
            else if let oldIDs = previouslySelectedIDs,
                    let best = next.max(by: { Set($0.assetIDs).intersection(oldIDs).count < Set($1.assetIDs).intersection(oldIDs).count }),
                    !Set(best.assetIDs).intersection(oldIDs).isEmpty { selectedEventIndex = best.index }
            else { selectedEventIndex = next.max(by: { $0.photoCount < $1.photoCount })?.index }
            progressMessage = acceptedModel == nil ? "Occasions grouped on this device." : "Occasions separated using small thumbnails."
        } catch {
            occasionSplitResult = nil
            events = EventSegmenter.segment(records)
            selectedEventIndex = preserveAllEventsChoice ? nil : events.max(by: { $0.photoCount < $1.photoCount })?.index
            progressMessage = "Using date-based event groups."
        }
    }

    var configuredResponsesClient: ResponsesClient? {
        injectedClient ?? workerEndpoint.flatMap { url in
            guard !workerInviteToken.isEmpty else { return nil }
            return ResponsesClient(transport: WorkerTransport(endpoint: url, inviteToken: workerInviteToken))
        }
    }

    func generateOptions() async -> Bool {
        guard let importedFolder else { return false }
        if modelAssist && configuredResponsesClient == nil {
            showWorkerSettings = true
            return false
        }
        guard !modelAssist || allowThumbnailTransfer else {
            showThumbnailDisclosure = true
            return false
        }
        isGenerating = true
        failureMessage = nil
        retryImport = false
        do {
            let endpoint = workerEndpoint
            let client = configuredResponsesClient
            let useModelAssistance = modelAssist && client != nil
            let configProvider = useModelAssistance ? (injectedStylePackProvider ?? endpoint.map { url in
                let configURL = url.appending(path: "v1/config")
                return { try await StyleConfigClient.fetch(from: configURL) }
            }) : nil
            progressMessage = "Preparing your photos…"
            let generated = try await StoryPipeline(responsesClient: client, stylePackProvider: configProvider)
                .run(folder: importedFolder, modelAssist: useModelAssistance, importDuration: importDuration,
                     eventAssetIDs: selectedEventIndex.flatMap { selected in events.first { $0.index == selected }.map { Set($0.assetIDs) } },
                     storyHint: storyHint.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                     eventSegments: events, occasionResult: occasionSplitResult) { [weak self] message in
                    Task { @MainActor in self?.progressMessage = message }
                }
            options = generated
            retainedSourceFolders.formUnion(generated.map(\.sourceFolder))
            selectedOptionID = generated.first?.id
            state = .ready
            progressMessage = "Options are ready."
            isGenerating = false
            return true
        } catch {
            failureMessage = "Option generation failed. Retry to start a clean run. (\(error.localizedDescription))"
            state = .failed("Could not build options: \(error.localizedDescription)")
            progressMessage = "Preparing…"
            isGenerating = false
            return false
        }
    }

    func retry() async -> Bool {
        if retryImport { return await importSelection() }
        return await generateOptions()
    }

    func saveSelectedOption() async {
        guard let option = selectedOption else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            state = .failed("Allow AK14 to add photos in Settings to save the slides.")
            return
        }
        isSaving = true
        do {
            try await Self.performSave(option.slides)
            let snapshot = try? await storyEditor(for: option).snapshotHandoff(for: option.id)
            recorder(for: option).record("carousel_exported", conceptID: option.id,
                                         after: ["\(option.slides.count) slides"] + (snapshot.map { ["snapshot=\($0)"] } ?? []))
            handedOffRuns.insert(option.runDirectory.standardizedFileURL)
            alert = AlertMessage(title: "Saved to Photos", message: "Saved \(option.slides.count) slides in order.")
            successfulSaves += 1
        } catch { state = .failed("Could not save slides: \(error.localizedDescription)") }
        isSaving = false
    }

    func selectOption(_ option: StoryOption) {
        selectedOptionID = option.id
        recorder(for: option).record("concept_selected", conceptID: option.id)
    }

    func presentOptions(for option: StoryOption) {
        let run = option.runDirectory.standardizedFileURL
        guard presentedRuns.insert(run).inserted else { return }
        recorder(for: option).record("concepts_presented")
    }

    func leaveOptions(for option: StoryOption) {
        let run = option.runDirectory.standardizedFileURL
        guard !handedOffRuns.contains(run), abandonedRuns.insert(run).inserted else { return }
        recorder(for: option).record("generation_abandoned")
    }

    func shareCompleted(for option: StoryOption, activityType: UIActivity.ActivityType?) async {
        guard let activityType else { return }
        let snapshot = try? await storyEditor(for: option).snapshotHandoff(for: option.id)
        recorder(for: option).record("carousel_shared", conceptID: option.id,
                                     after: [activityType.rawValue] + (snapshot.map { ["snapshot=\($0)"] } ?? []))
        handedOffRuns.insert(option.runDirectory.standardizedFileURL)
    }

    func applyEdit(_ edit: PlanEdit, to optionID: String) async -> [URL]? {
        guard let index = options.firstIndex(where: { $0.id == optionID }) else { return nil }
        let option = options[index]
        isEditingOption = true
        defer { isEditingOption = false }
        do {
            let editor = try storyEditor(for: option)
            let slides = try await editor.apply(edit, to: option.id)
            options[index] = StoryOption(id: option.id, title: option.title, slides: slides,
                                         stylePackPin: option.stylePackPin, generationMode: option.generationMode,
                                         runDirectory: option.runDirectory, sourceFolder: option.sourceFolder)
            return slides
        } catch {
            state = .failed("Could not update this option: \(error.localizedDescription)")
            return nil
        }
    }

    func planForOption(_ optionID: String) async -> CarouselPlan? {
        guard let option = options.first(where: { $0.id == optionID }) else { return nil }
        do { return try await storyEditor(for: option).plan(for: option.id) }
        catch {
            state = .failed("Could not open slide editing: \(error.localizedDescription)")
            return nil
        }
    }

    private func storyEditor(for option: StoryOption) throws -> StoryEditingService {
        let runDirectory = option.runDirectory.standardizedFileURL
        if let cached = storyEditors[runDirectory] { return cached }
        let editor = try StoryEditingService(runDirectory: runDirectory, sourceFolder: option.sourceFolder,
                                             interactionRecorder: recorder(for: option))
        storyEditors[runDirectory] = editor
        return editor
    }

    private func recorder(for option: StoryOption) -> InteractionRecorder {
        let directory = option.runDirectory.standardizedFileURL
        if let recorder = interactionRecorders[directory] { return recorder }
        let recorder = InteractionRecorder(runDirectory: directory)
        interactionRecorders[directory] = recorder
        return recorder
    }

    var selectedOption: StoryOption? { options.first { $0.id == selectedOptionID } }
    var workerEndpoint: URL? {
        let raw = workerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        guard scheme == "https" || (scheme == "http" && localHosts.contains(host)) else { return nil }
        return url
    }
    var hasWorkerConfig: Bool { injectedClient != nil || (workerEndpoint != nil && !workerInviteToken.isEmpty) }

    private enum SaveFailure: LocalizedError {
        case failed
        var errorDescription: String? { "Photos did not accept the save request." }
    }

    private nonisolated static func performSave(_ urls: [URL]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let changes: @Sendable () -> Void = {
                for url in urls {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: SaveFailure.failed) }
            }
        }
    }

    private func fileExtension(_ asset: PHAsset) -> String {
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .fullSizePhoto })
                ?? PHAssetResource.assetResources(for: asset).first,
              let ext = UTType(filenameExtension: (resource.originalFilename as NSString).pathExtension)?.preferredFilenameExtension else { return "jpg" }
        return ext
    }

    private func copyOriginal(_ asset: PHAsset, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizePhoto }) ?? resources.first else {
            throw ImportFailure.noResource
        }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = progress
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private enum ImportFailure: LocalizedError {
        case noResource, noReadablePhotos
        case iCloudDownloadFailed(String)
        var errorDescription: String? {
            switch self {
            case .noResource: "The selected photo has no readable original."
            case .noReadablePhotos: "None of the selected photos could be read. Choose another selection and try again."
            case .iCloudDownloadFailed(let detail): "iCloud photo download failed. Check your internet connection and retry. (\(detail))"
            }
        }
    }
}
import Core
import Photos
import Render
import SwiftUI
import UIKit

private enum ImportRoute: Hashable {
    case review
    case options
}

private enum ImportStage: Int, CaseIterable {
    case photos, review, options

    var title: String {
        switch self {
        case .photos: "Photos"
        case .review: "Review"
        case .options: "Options"
        }
    }
}

struct ImportReviewView: View {
    @State private var model: ImportReviewModel
    @State private var path: [ImportRoute] = []
    @State private var importTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 5)]

    init(client: ResponsesClient? = nil,
         stylePackProvider: (@Sendable () async throws -> LoadedStylePack)? = nil) {
        _model = State(initialValue: ImportReviewModel(client: client, stylePackProvider: stylePackProvider))
    }

    var body: some View {
        NavigationStack(path: $path) {
            photosStage
                .navigationDestination(for: ImportRoute.self) { route in
                    switch route {
                    case .review: reviewStage
                    case .options: optionsStage
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { model.showWorkerSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("AI story settings")
                    }
                }
                .sheet(isPresented: $model.showWorkerSettings) { workerSettings }
                .sheet(isPresented: $model.sharePresented) {
                    ActivityShareSheet(items: model.shareURLs) { activityType, completed in
                        guard completed, let option = model.selectedOption else { return }
                        Task { await model.shareCompleted(for: option, activityType: activityType) }
                    }
                }
                .alert(item: $model.alert) { alert in
                    Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
                }
                .alert("Send selected thumbnails?", isPresented: $model.showThumbnailDisclosure) {
                    Button("Allow and create options") {
                        model.allowThumbnailTransfer = true
                        Task { if await model.generateOptions() { path.append(.options) } }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Small selected thumbnails and short descriptions will be sent to the AK14 Worker and OpenAI for story planning. Full-resolution originals stay on this device.")
                }
                .onChange(of: model.state) { _, state in
                    guard case .failed(let message) = state else { return }
                    model.alert = .init(title: "Could not continue", message: message)
                    model.state = model.records.isEmpty ? .idle : .ready
                }
                .onChange(of: model.modelAssist) { _, enabled in
                    UserDefaults.standard.set(enabled, forKey: "ak14.modelAssist")
                    guard !model.records.isEmpty else { return }
                    Task { await model.prepareOccasionChoices(useModel: enabled) }
                }
                .onChange(of: model.allowThumbnailTransfer) { _, allowed in
                    guard !model.records.isEmpty, model.modelAssist else { return }
                    Task { await model.prepareOccasionChoices(useModel: allowed) }
                }
        }
    }

    private var photosStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                StageProgress(active: .photos)
                Text("Choose photos for your story.")
                    .font(.title3.weight(.semibold))
                if model.authorization == .authorized || model.authorization == .limited {
                    dateControls
                    selectionHeader
                    if model.state == .loading {
                        ProgressView("Finding photos…").frame(maxWidth: .infinity, minHeight: 180)
                    } else if model.assets.isEmpty {
                        ContentUnavailableView("No photos in this range", systemImage: "photo.on.rectangle.angled",
                                               description: Text("Choose another date range to find photos."))
                            .frame(minHeight: 220)
                    } else {
                        LazyVGrid(columns: columns, spacing: 5) {
                            ForEach(Array(model.assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                                AssetTile(asset: asset, ordinal: index + 1, total: model.assets.count,
                                          selected: model.selectedIDs.contains(asset.localIdentifier)) {
                                    model.toggle(asset)
                                }
                            }
                        }
                        .accessibilityLabel("Photo selection")
                    }
                    if model.authorization == .limited {
                        Label("Limited Photos access", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Choose more photos") { model.showLimitedLibraryPicker = true }
                            .font(.caption)
                    }
                } else {
                    permissionCard
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Photos")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) { photoFooter }
        .task {
            model.authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if model.authorization == .authorized || model.authorization == .limited, model.assets.isEmpty {
                await model.loadAssets()
            }
        }
        .background {
            LimitedLibraryPickerPresenter(isPresented: $model.showLimitedLibraryPicker) {
                model.authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                Task { await model.loadAssets() }
            }
            .frame(width: 0, height: 0)
        }
        .sensoryFeedback(.selection, trigger: model.selectedIDs.count)
    }

    private var permissionCard: some View {
        ContentUnavailableView {
            Label("Choose photos", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("AK14 uses the photos you select to make a story. Your originals stay on this device.")
        }
        .frame(minHeight: 340)
    }

    private var datePickers: some View {
        VStack(alignment: .leading, spacing: 8) {
            DatePicker("From", selection: $model.startDate, displayedComponents: .date)
            DatePicker("To", selection: $model.endDate, displayedComponents: .date)
        }
    }

    private var dateControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            datePickers
            HStack {
                Text(model.authorization == .limited ? "Showing photos you allowed" : "Filter your library by date")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    Task { await model.loadAssets() }
                } label: {
                    if model.state == .loading { ProgressView().controlSize(.small) }
                    else { Label("Find photos", systemImage: "magnifyingglass") }
                }
                .labelStyle(.titleAndIcon)
                .disabled(model.state == .loading || model.state == .importing)
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private var selectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(model.selectedIDs.count) selected")
                .font(.headline).contentTransition(.numericText())
                .accessibilityLabel("\(model.selectedIDs.count) photos selected")
            Spacer()
            Button("Select all") { model.selectedIDs = Set(model.assets.map(\.localIdentifier)) }
                .disabled(model.assets.isEmpty || model.selectedIDs.count == model.assets.count)
            Button("Clear") { model.selectedIDs.removeAll() }
                .disabled(model.selectedIDs.isEmpty)
        }
        .buttonStyle(.borderless)
    }

    private var photoFooter: some View {
        Group {
            if model.state == .importing {
                HStack(spacing: 12) {
                    ProgressView(value: Double(model.importCompleted), total: Double(max(1, model.importTotal)))
                        .tint(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.progressMessage).font(.subheadline.weight(.semibold))
                            .accessibilityAddTraits(.updatesFrequently)
                        Text("\(model.importCompleted) of \(model.importTotal)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) { importTask?.cancel() }
                        .accessibilityHint("Stops after the photo currently being copied")
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            } else if let failure = model.failureMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(failure, systemImage: "exclamationmark.icloud")
                        .font(.footnote).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry import") {
                        importTask = Task { if await model.retry() { path.append(.review) } }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.vertical, 12)
            } else if model.authorization != .authorized && model.authorization != .limited {
                Button {
                    if model.authorization == .denied || model.authorization == .restricted {
                        openSettings()
                    } else {
                        Task { await model.requestAccessAndLoad() }
                    }
                } label: {
                    Text(model.authorization == .denied || model.authorization == .restricted
                         ? "Open Settings" : "Choose photos")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.state == .requestingAccess)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .accessibilityIdentifier("photosPermissionCTA")
                .accessibilityHint("Grants AK14 access to the photos you choose")
            } else {
                Button {
                    importTask = Task {
                        if await model.importSelection() { path.append(.review) }
                    }
                } label: {
                    Text("Review \(model.selectedIDs.count) selected photos")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.selectedIDs.isEmpty || model.state == .loading || model.state == .requestingAccess)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .accessibilityHint("Copies the selected originals to prepare them for review")
            }
        }
        .background(.regularMaterial)
    }

    private var reviewStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StageProgress(active: .review)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Review your selection")
                        .font(.title2.weight(.semibold))
                    Text("\(model.records.count) photos ready\(dateSummary.map { " · \($0)" } ?? "")")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(model.records) { record in
                            if let folder = model.importedFolder {
                                ImportedThumbnail(record: record, folder: folder)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .accessibilityLabel("Selected photos")

                if model.events.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.isPreparingOccasions ? "Finding occasions…" : "Choose an event").font(.headline)
                        if model.isPreparingOccasions {
                            ProgressView(model.modelAssist ? "Classifying representative thumbnails…" : "Analyzing scene signatures on device…")
                        }
                        ForEach(model.events, id: \.index) { event in
                            Button {
                                model.selectedEventIndex = event.index
                            } label: {
                                HStack(spacing: 12) {
                                    EventCover(event: event, records: model.records, folder: model.importedFolder)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(event.dateRangeLabel).font(.body)
                                        Text("\(event.photoCount) photos").font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: model.selectedEventIndex == event.index ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(model.selectedEventIndex == event.index ? Color.accentColor : .secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isPreparingOccasions)
                            .accessibilityLabel("\(event.dateRangeLabel), \(event.photoCount) photos")
                            .accessibilityIdentifier("eventChoice-\(event.index)")
                            .accessibilityAddTraits(model.selectedEventIndex == event.index ? .isSelected : [])
                        }
                        Button {
                            model.selectedEventIndex = nil
                        } label: {
                            Label("One story across all events", systemImage: model.selectedEventIndex == nil ? "largecircle.fill.circle" : "circle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("allEventsChoice")
                        .accessibilityAddTraits(model.selectedEventIndex == nil ? .isSelected : [])
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 16))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Story hint (optional)").font(.headline)
                    TextField("What's this post about? e.g. Munnar trip with my cousins — the misty hike is the highlight, skip the hotel shots", text: $model.storyHint, axis: .vertical)
                        .lineLimit(3...5)
                        .accessibilityLabel("Story hint")
                        .accessibilityIdentifier("storyHintField")
                        .onChange(of: model.storyHint) { _, value in
                            if value.count > 280 { model.storyHint = String(value.prefix(280)) }
                        }
                    Text("\(model.storyHint.count)/280")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityLabel("\(model.storyHint.count) of 280 characters")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 12) {
                    Label("Your originals stay on this device.", systemImage: "lock.shield")
                        .font(.subheadline.weight(.semibold))
                    if model.hasWorkerConfig {
                        Toggle("Use AI-assisted story planning", isOn: $model.modelAssist)
                            .accessibilityHint("When on, selected thumbnails and short descriptions are sent to the configured Worker. Full-resolution originals stay on this device.")
                        if model.modelAssist {
                            Toggle("Allow selected thumbnails to be sent", isOn: $model.allowThumbnailTransfer)
                            Text("When allowed, selected small thumbnails and short descriptions go to the AK14 Worker and OpenAI to plan story directions. Full-resolution originals stay on this device.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            localModeExplanation
                        }
                    } else {
                        Toggle("Use AI-assisted story planning", isOn: $model.modelAssist)
                        Text("AI planning is on by default. Add your scoped invite token before creating options. No photos are sent until you allow thumbnail transfer below.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if model.modelAssist {
                            Toggle("Allow selected thumbnails to be sent", isOn: $model.allowThumbnailTransfer)
                        }
                        if !model.modelAssist { localModeExplanation }
                        Button("Set up AI-assisted planning") { model.showWorkerSettings = true }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(18)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) { reviewFooter }
    }

    private var localModeExplanation: some View {
        Text("Create a photos-only story using on-device photo analysis and layout. No thumbnails or descriptions are sent to a model.")
            .font(.footnote).foregroundStyle(.secondary)
    }

    private var reviewFooter: some View {
        Group {
            if model.isGenerating {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView()
                    Text(model.progressMessage).font(.subheadline)
                        .accessibilityAddTraits(.updatesFrequently)
                        .accessibilityLabel("Generation progress: \(model.progressMessage)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.vertical, 12)
            } else if let failure = model.failureMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry generation") {
                        Task { if await model.retry() { path.append(.options) } }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.vertical, 12)
            } else {
                Button {
                    Task {
                        if await model.generateOptions() { path.append(.options) }
                    }
                } label: {
                    Text("Create options").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .padding(.horizontal, 18).padding(.vertical, 10)
            }
        }
        .background(.regularMaterial)
    }

    private var optionsStage: some View {
        OptionsReviewStage(model: model)
    }

    private var dateSummary: String? {
        let dates = model.records.compactMap { $0.metadata.capturedAt }.sorted()
        guard let first = dates.first, let last = dates.last else { return nil }
        let style: Date.FormatStyle = .dateTime.month(.abbreviated).day()
        if Calendar.current.isDate(first, inSameDayAs: last) { return first.formatted(style) }
        return "\(first.formatted(style))–\(last.formatted(style))"
    }

    private var workerSettings: some View {
        NavigationStack {
            Form {
                Section("AI-assisted planning") {
                    TextField("Worker URL", text: $model.workerBaseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("Invite token", text: $model.workerInviteToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Your invite token is saved securely on this device. The Worker URL is saved in app preferences.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text(model.hasWorkerConfig
                         ? "AI-assisted planning is available. You choose whether to send selected thumbnails and short descriptions for each story."
                         : "Add your HTTPS Worker URL and invite token to enable AI-assisted planning. HTTP localhost is available for simulator development.")
                        .font(.callout)
                }
            }
            .onChange(of: model.workerBaseURL) { _, value in
                UserDefaults.standard.set(value, forKey: "ak14.workerBaseURL")
            }
            .onChange(of: model.workerInviteToken) { _, value in
                WorkerInviteToken.save(value)
            }
            .navigationTitle("Story settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.showWorkerSettings = false }
                }
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension EventSegment {
    var dateRangeLabel: String {
        let style: Date.FormatStyle = .dateTime.month(.abbreviated).day()
        guard let start else { return "Undated event" }
        guard let end, !Calendar.current.isDate(start, inSameDayAs: end) else { return start.formatted(style) }
        return "\(start.formatted(style)) – \(end.formatted(style))"
    }
}

private struct EventCover: View {
    let event: EventSegment
    let records: [PhotoRecord]
    let folder: URL?
    var body: some View {
        Group {
            if let record = records.first(where: { event.assetIDs.contains($0.assetID) }), let folder {
                ImportedThumbnail(record: record, folder: folder)
            } else { RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 52, height: 52) }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

private struct StageProgress: View {
    let active: ImportStage

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ImportStage.allCases, id: \.rawValue) { stage in
                HStack(spacing: 5) {
                    Text("\(stage.rawValue + 1)")
                        .font(.caption2.weight(.bold))
                        .frame(width: 22, height: 22)
                        .background(stage == active ? Color.accentColor : Color(uiColor: .tertiarySystemFill), in: Circle())
                        .foregroundStyle(stage == active ? Color.white : Color.secondary)
                    Text(stage.title)
                        .font(.caption.weight(stage == active ? .semibold : .regular))
                        .foregroundStyle(stage == active ? Color.primary : Color.secondary)
                }
                if stage != ImportStage.allCases.last { Spacer(minLength: 0) }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(active.rawValue + 1) of 3: \(active.title)")
    }
}

private struct AssetTile: View {
    let asset: PHAsset
    let ordinal: Int
    let total: Int
    let selected: Bool
    let action: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: action) {
            GeometryReader { geometry in
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let image { Image(uiImage: image).resizable().scaledToFill() }
                        else { Rectangle().fill(.quaternary).overlay(ProgressView()) }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    Circle()
                        .fill(.regularMaterial)
                        .frame(width: 27, height: 27)
                        .overlay {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, selected ? .blue : .white.opacity(0.8))
                                .font(.title3)
                        }
                        .padding(7)
                }
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(photoLabel)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint("Double-tap to change whether this photo is included")
        .accessibilityIdentifier("photo-\(ordinal)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .task(id: asset.localIdentifier) {
            let request = PHImageRequestOptions()
            request.deliveryMode = .opportunistic
            request.isNetworkAccessAllowed = true
            image = await withCheckedContinuation { continuation in
                PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 320, height: 320),
                                                      contentMode: .aspectFill, options: request) { image, info in
                    if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
                    continuation.resume(returning: image)
                }
            }
        }
    }

    private var photoLabel: String {
        var details = asset.mediaSubtypes.contains(.photoLive) ? "Live Photo" : "Photo"
        if asset.mediaSubtypes.contains(.photoScreenshot) { details += ", screenshot" }
        if let date = asset.creationDate {
            details += ", " + date.formatted(date: .abbreviated, time: .shortened)
        } else {
            details += ", date unavailable"
        }
        return "\(details), \(ordinal) of \(total)"
    }
}

private struct LimitedLibraryPickerPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onSelectionChanged: () -> Void

    @MainActor final class Coordinator {
        var isPresenting = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        let coordinator = context.coordinator
        guard isPresented, !coordinator.isPresenting, controller.viewIfLoaded?.window != nil else { return }
        coordinator.isPresenting = true
        DispatchQueue.main.async {
            guard isPresented else { coordinator.isPresenting = false; return }
            isPresented = false
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller) { _ in
                DispatchQueue.main.async {
                    coordinator.isPresenting = false
                    onSelectionChanged()
                }
            }
        }
    }
}

private struct ImportedThumbnail: View {
    let record: PhotoRecord
    let folder: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Rectangle().fill(.quaternary).overlay(ProgressView()) }
        }
        .frame(width: 116, height: 116).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel(record.metadata.capturedAt?.formatted(date: .abbreviated, time: .omitted) ?? "Selected photo")
        .task(id: record.assetID) {
            let source = folder.appending(path: record.sourceRelativePaths[0])
            let cache = FileManager.default.temporaryDirectory.appending(path: "AK14-review-cache", directoryHint: .isDirectory)
            guard let thumbnailURL = try? await Task.detached(priority: .utility, operation: {
                try Thumbnailer(cacheRoot: cache).thumbnail(sha: record.contentSHA256, source: source, tier: .triage)
            }).value, let data = try? Data(contentsOf: thumbnailURL) else { return }
            image = UIImage(data: data)
        }
    }
}

private struct OptionsReviewStage: View {
    @Bindable var model: ImportReviewModel
    @State private var slideIndex = 0
    @State private var currentPlan: CarouselPlan?
    @State private var editorPresented = false
    @State private var isLoadingPlan = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var option: StoryOption? { model.selectedOption }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    StageProgress(active: .options).padding(.horizontal, 18)
                    Text("Choose an option")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                    optionPicker
                    if let option {
                        if editorPresented {
                            Color.clear
                                .frame(height: max(240, geometry.size.height * 0.42))
                                .accessibilityHidden(true)
                        } else {
                            TabView(selection: $slideIndex) {
                                ForEach(Array(option.slides.enumerated()), id: \.offset) { index, url in
                                    SlidePreview(url: url, index: index, count: option.slides.count)
                                        .tag(index)
                                }
                            }
                            .tabViewStyle(.page(indexDisplayMode: .never))
                            .accessibilityLabel("Slides for \(option.title)")
                            .frame(height: max(240, min(geometry.size.height * 0.48, 560)))
                        }
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.stack")
                            Text("Slide \(min(slideIndex + 1, option.slides.count)) of \(option.slides.count)")
                                .contentTransition(.numericText())
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Slide \(min(slideIndex + 1, option.slides.count)) of \(option.slides.count)")
                        if currentPlan != nil {
                            Button {
                                editorPresented = true
                            } label: {
                                Label("Edit slides", systemImage: "arrow.up.arrow.down")
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isEditingOption)
                        } else if isLoadingPlan {
                            ProgressView("Preparing slide editing…")
                                .font(.footnote)
                                .accessibilityAddTraits(.updatesFrequently)
                        }
                        if option.generationMode == .photosOnly {
                            Text("Created on this device from your selected photos.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .padding(.horizontal, 18)
                        }
                    } else {
                        ContentUnavailableView("No options available", systemImage: "photo.stack")
                    }
                }
                .padding(.bottom, 16)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollIndicators(.hidden)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Options")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .topLeading) {
            if let option {
                Text(option.runDirectory.appending(path: "interaction-events.jsonl").path)
                    .font(.system(size: 1)).foregroundStyle(.clear)
                    .accessibilityIdentifier("interactionLogPath")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionFooter }
        .sensoryFeedback(.success, trigger: model.successfulSaves)
        .onChange(of: model.selectedOptionID) { _, _ in
            slideIndex = 0
            currentPlan = nil
            isLoadingPlan = true
        }
        .task(id: option?.id) {
            guard let option else { currentPlan = nil; isLoadingPlan = false; return }
            isLoadingPlan = true
            model.presentOptions(for: option)
            currentPlan = await model.planForOption(option.id)
            isLoadingPlan = false
        }
        .onDisappear {
            if let option { model.leaveOptions(for: option) }
        }
        .sheet(isPresented: $editorPresented) {
            if let option, let currentPlan {
                SlideEditorSheet(option: option, plan: currentPlan, photos: model.records) { edit in
                    let result = await model.applyEdit(edit, to: option.id)
                    if let result {
                        slideIndex = min(slideIndex, max(0, result.count - 1))
                        self.currentPlan = await model.planForOption(option.id)
                    }
                    return result
                }
                .id(option.id)
                .interactiveDismissDisabled()
            }
        }
    }

    private var optionPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(model.options.enumerated()), id: \.element.id) { index, candidate in
                    let selected = candidate.id == model.selectedOptionID
                    Button {
                        if reduceMotion { model.selectOption(candidate) }
                        else { withAnimation(.snappy(duration: 0.22)) { model.selectOption(candidate) } }
                    } label: {
                        Text(candidate.title.isEmpty ? "Option \(index + 1)" : candidate.title)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(selected ? Color.accentColor.opacity(0.14) : Color(uiColor: .secondarySystemGroupedBackground),
                                        in: Capsule())
                            .overlay(Capsule().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(candidate.title.isEmpty ? "Option \(index + 1)" : candidate.title), \(candidate.slides.count) slides")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 18)
        }
        .scrollIndicators(.hidden)
    }

    private var actionFooter: some View {
        HStack(spacing: 12) {
            Button {
                guard let option else { return }
                model.shareURLs = option.slides
                model.sharePresented = true
            } label: {
                Label("Share slides", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(option == nil)

            Button {
                Task { await model.saveSelectedOption() }
            } label: {
                if model.isSaving { ProgressView().frame(maxWidth: .infinity) }
                else { Label("Save to Photos", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(option == nil || model.isSaving)
        }
        .controlSize(.large)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.regularMaterial)
    }
}

private struct SlideEditorSheet: View {
    let option: StoryOption
    @Environment(\.dismiss) private var dismiss
    @State private var plan: CarouselPlan
    @State private var slides: [URL]
    @State private var selectedSlideForRemoval: Int?
    @State private var photoPickerPresented = false
    @State private var isApplying = false
    let photos: [PhotoRecord]
    let onEdit: (PlanEdit) async -> [URL]?

    init(option: StoryOption, plan: CarouselPlan, photos: [PhotoRecord],
         onEdit: @escaping (PlanEdit) async -> [URL]?) {
        self.option = option
        self.photos = photos
        self.onEdit = onEdit
        _plan = State(initialValue: plan)
        _slides = State(initialValue: option.slides)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Move slides with the arrows. Removing a photo changes this option only; the original photos remain in Photos.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Slides") {
                    ForEach(Array(slides.enumerated()), id: \.offset) { index, url in
                        slideRow(index: index, url: url)
                    }
                }
            }
            .navigationTitle("Edit slides")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(isApplying)
                }
            }
            .overlay {
                if isApplying { ProgressView("Updating option…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) }
            }
        }
        .sheet(isPresented: $photoPickerPresented) {
            if let index = selectedSlideForRemoval, plan.slides.indices.contains(index) {
                let ids = Set(plan.slides[index].photos.map(\.assetID))
                PhotoRemovalPicker(records: photos.filter { ids.contains($0.assetID) }, folder: option.sourceFolder) { id in
                    await apply(.remove(slide: index, photo: id))
                }
            }
        }
    }

    @ViewBuilder
    private func slideRow(index: Int, url: URL) -> some View {
        HStack(spacing: 12) {
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 52, height: 66).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
            }
            Text("Slide \(index + 1)").font(.body.weight(.medium))
            Spacer(minLength: 4)
            Button {
                beginApply(.reorder(from: index, to: index - 1))
            } label: { Image(systemName: "arrow.up") }
                .disabled(index == 0 || isApplying)
                .accessibilityLabel("Move slide \(index + 1) earlier")
            Button {
                beginApply(.reorder(from: index, to: index + 1))
            } label: { Image(systemName: "arrow.down") }
                .disabled(index == slides.count - 1 || isApplying)
                .accessibilityLabel("Move slide \(index + 1) later")
            if plan.slides.indices.contains(index) {
                let slide = plan.slides[index]
                if slide.photos.count == 1 {
                    Button(role: .destructive) {
                        beginApply(.remove(slide: index, photo: slide.photos[0].assetID))
                    } label: { Image(systemName: "trash") }
                        .disabled(plan.photoAssetIDs.count <= 1 || isApplying)
                        .accessibilityLabel("Remove photo from slide \(index + 1)")
                } else {
                    Button {
                        selectedSlideForRemoval = index
                        photoPickerPresented = true
                    } label: { Image(systemName: "minus.circle") }
                        .disabled(isApplying)
                        .accessibilityLabel("Choose a photo to remove from slide \(index + 1)")
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func beginApply(_ edit: PlanEdit) {
        guard !isApplying else { return }
        isApplying = true
        Task { _ = await apply(edit) }
    }

    private func apply(_ edit: PlanEdit) async -> [URL]? {
        isApplying = true
        defer { isApplying = false }
        guard let nextPlan = try? PlanEditor.apply(edit, to: plan) else { return nil }
        guard let updatedSlides = await onEdit(edit) else { return nil }
        plan = nextPlan
        slides = updatedSlides
        return updatedSlides
    }
}

private struct PhotoRemovalPicker: View {
    let records: [PhotoRecord]
    let folder: URL
    let onRemove: (AssetID) async -> [URL]?
    @Environment(\.dismiss) private var dismiss
    @State private var isRemoving = false

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 10)]

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    ContentUnavailableView("Photos unavailable", systemImage: "photo")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(records) { record in
                                Button {
                                    isRemoving = true
                                    Task {
                                        if await onRemove(record.assetID) != nil { dismiss() }
                                        isRemoving = false
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ImportedThumbnail(record: record, folder: folder)
                                            .frame(maxWidth: .infinity)
                                        Text(record.metadata.capturedAt?.formatted(date: .abbreviated, time: .omitted) ?? "Selected photo")
                                            .font(.caption).foregroundStyle(.primary).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove photo from this option, \(record.metadata.capturedAt?.formatted(date: .abbreviated, time: .omitted) ?? "date unavailable")")
                                .disabled(isRemoving)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Choose photo to remove")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if isRemoving { ProgressView("Updating option…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) }
            }
        }
    }
}

private struct SlidePreview: View {
    let url: URL
    let index: Int
    let count: Int

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    ContentUnavailableView("Slide unavailable", systemImage: "photo")
                }
            }
            .overlay(alignment: .topLeading) {
                Text("\(index + 1) / \(count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(12)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Slide \(index + 1) of \(count)")
        }
        .padding(.horizontal, 16)
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    let onCompletion: @MainActor (UIActivity.ActivityType?, Bool) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { activityType, completed, _, _ in
            Task { @MainActor in onCompletion(activityType, completed) }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private enum WorkerInviteToken {
    private static let service = "com.ak14.worker-invite"
    private static let account = "scoped-invite"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(clean.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(insertion as CFDictionary, nil)
        }
    }
}
