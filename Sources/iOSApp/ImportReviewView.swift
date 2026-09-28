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
    var selectionOrder: [String] = []
    var exactSet = false
    var keepOrder = false
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
    var modelAssist = UserDefaults.standard.object(forKey: "ak14.modelAssist") == nil ? true : UserDefaults.standard.bool(forKey: "ak14.modelAssist")
    var shareURLs: [URL] = []
    var sharePresented = false
    var showWorkerSettings = false
    var showLimitedLibraryPicker = false
    var showSystemPicker = false
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
        selectedIDs = Set(assets.map(\.localIdentifier))
        selectionOrder = assets.map(\.localIdentifier)
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

    func usePickedAssets(_ identifiers: [String]) {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var byID: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        let ordered = identifiers.compactMap { byID[$0] }
        guard !ordered.isEmpty else { return }
        assets = ordered
        selectedIDs = Set(ordered.map(\.localIdentifier))
        selectionOrder = ordered.map(\.localIdentifier)
        exactSet = true
        keepOrder = true
    }

    func toggle(_ asset: PHAsset) {
        if selectedIDs.contains(asset.localIdentifier) { selectedIDs.remove(asset.localIdentifier); selectionOrder.removeAll { $0 == asset.localIdentifier } }
        else { selectedIDs.insert(asset.localIdentifier); selectionOrder.append(asset.localIdentifier) }
    }

    func importSelection() async -> Bool {
        let orderedAssets = selectionOrder.compactMap { id in assets.first { $0.localIdentifier == id } }
        let chosen = orderedAssets + assets.filter { selectedIDs.contains($0.localIdentifier) && !selectionOrder.contains($0.localIdentifier) }
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
                progressMessage = "Photo \(photoNumber) of \(totalPhotos)"
                try await copyOriginal(asset, to: folder.appending(path: String(format: "photo-%04d.%@", index, fileExtension(asset)))) { _ in }
                importCompleted = index + 1
            }
            try Task.checkCancellation()
            let result = try await FolderIngester().ingest(folder: folder, options: IngestOptions())
            if let old = importedFolder, !retainedSourceFolders.contains(old) {
                try? FileManager.default.removeItem(at: old)
            }
            importedFolder = folder
            importDuration = (ContinuousClock().now - importStart).seconds
            records = result.photos.sorted { ($0.sourceRelativePaths.first ?? "") < ($1.sourceRelativePaths.first ?? "") }
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
        let client = useModel ? configuredResponsesClient : nil
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
                for photo in records {
                    try Task.checkCancellation()
                    let url = try thumbnailer.thumbnail(sha: photo.contentSHA256,
                        source: folder.appending(path: photo.sourceRelativePaths[0]), tier: .analysis)
                    thumbnails[photo.assetID] = url
                    progressMessage = "Sorting photos"
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
            progressMessage = "Photos sorted"
        } catch {
            occasionSplitResult = nil
            events = EventSegmenter.segment(records)
            selectedEventIndex = preserveAllEventsChoice ? nil : events.max(by: { $0.photoCount < $1.photoCount })?.index
            progressMessage = "Photos sorted"
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
            progressMessage = "Preparing photos"
            let generated = try await StoryPipeline(responsesClient: client, stylePackProvider: configProvider)
                .run(folder: importedFolder, modelAssist: useModelAssistance, importDuration: importDuration,
                     eventAssetIDs: selectedEventIndex.flatMap { selected in events.first { $0.index == selected }.map { Set($0.assetIDs) } },
                     storyHint: storyHint.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                     eventSegments: events, occasionResult: occasionSplitResult,
                     exactSet: exactSet, keepOrder: keepOrder) { [weak self] message in
                    Task { @MainActor in self?.progressMessage = message }
                }
            options = generated
            retainedSourceFolders.formUnion(generated.map(\.sourceFolder))
            selectedOptionID = generated.first { $0.id != "baseline" && $0.id != "plainDump" }?.id ?? generated.first?.id
            state = .ready
            progressMessage = "Options are ready."
            isGenerating = false
            return true
        } catch is CancellationError {
            isGenerating = false
            progressMessage = "Preparing…"
            return false
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
        await save(option.slides, for: option, snapshot: nil)
    }

    /// Saves exactly these rendered slides. `snapshot` names the document revision that produced them;
    /// without one, the story editor's current state is recorded.
    func save(_ slides: [URL], for option: StoryOption, snapshot: String?) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            state = .failed("Allow AK14 to add photos in Settings to save the slides.")
            return
        }
        isSaving = true
        do {
            try await Self.performSave(slides)
            let handoff: String?
            if let snapshot { handoff = snapshot } else { handoff = try? await storyEditor(for: option).snapshotHandoff(for: option.id) }
            recorder(for: option).record("carousel_exported", conceptID: option.id,
                                         after: ["\(slides.count) slides"] + (handoff.map { ["snapshot=\($0)"] } ?? []))
            handedOffRuns.insert(option.runDirectory.standardizedFileURL)
            alert = AlertMessage(title: "Saved to Photos", message: "Saved \(slides.count) slides in order.")
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

    func shareCompleted(for option: StoryOption, activityType: UIActivity.ActivityType?, snapshot recorded: String? = nil) async {
        guard let activityType else { return }
        let snapshot: String?
        if let recorded { snapshot = recorded } else { snapshot = try? await storyEditor(for: option).snapshotHandoff(for: option.id) }
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
                                         runDirectory: option.runDirectory, sourceFolder: option.sourceFolder,
                                         modelAssistRequested: option.modelAssistRequested)
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

private enum ImportRoute: Hashable {
    case review
    case options
}

struct ImportReviewView: View {
    @State private var model: ImportReviewModel
    @State private var path: [ImportRoute] = []
    @State private var importTask: Task<Void, Never>?
    @State private var generateTask: Task<Void, Never>?
    @State private var isImportingIncomingBatch = false
    @State private var didSeedIncomingBatch = false
    @State private var showAllPhotos = false
    @FocusState private var storyHintFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

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
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("Select all") {
                                model.selectedIDs = Set(model.assets.map(\.localIdentifier))
                                model.selectionOrder = model.assets.map(\.localIdentifier)
                            }
                            Button("Select none") {
                                model.selectedIDs = []
                                model.selectionOrder = []
                            }
                        } label: {
                            Image(systemName: "checklist")
                        }
                        .accessibilityLabel("Selection options")
                        .disabled(model.exactSet || model.assets.isEmpty)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { model.showWorkerSettings = true } label: {
                            Image(systemName: "gearshape")
                                .symbolEffect(.bounce, value: model.showWorkerSettings)
                        }
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
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await importIncomingBatch() } }
                }
                .task { await importIncomingBatch() }
                .onChange(of: path) { _, newPath in
                    if newPath.isEmpty { Task { await importIncomingBatch() } }
                }
        }
        .tint(AK14Palette.accent)
        .preferredColorScheme(.dark)
        .background(Color.black.ignoresSafeArea())
    }

    private var photosStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Choose photos for your story.")
                    .font(.title2.weight(.semibold))
                modeChoices
                if model.authorization == .authorized || model.authorization == .limited {
                    if model.exactSet {
                        exactPickerSection
                    } else {
                        dateControls
                        selectionHeader
                        rangeGrid
                    }
                    if model.authorization == .limited && !model.exactSet {
                        Button("Choose more photos") { model.showLimitedLibraryPicker = true }
                            .font(.footnote)
                    }
                } else {
                    permissionCard
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AppBackdrop())
        .containerBackground(Color.black, for: .navigation)
        .navigationTitle("Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) { photoFooter }
        .sheet(isPresented: $model.showSystemPicker) {
            SystemPhotoPicker { model.usePickedAssets($0) }
                .ignoresSafeArea()
        }
        .task {
            model.authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if model.authorization == .authorized || model.authorization == .limited, model.assets.isEmpty, !model.exactSet {
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

    private var modeChoices: some View {
        Picker("Photo selection mode", selection: Binding(
            get: { model.exactSet },
            set: { newValue in
                model.exactSet = newValue
                if !newValue, model.assets.isEmpty { Task { await model.loadAssets() } }
            }
        )) {
            Text("Best of a period").tag(false)
            Text("Pick exact photos").tag(true)
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Photo selection mode")
    }

    private var exactPickerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                model.showSystemPicker = true
            } label: {
                Label("Select photos", systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(model.state == .importing)
            Toggle("Keep my order", isOn: $model.keepOrder)
                .accessibilityHint("Uses photos in the order you selected them")
            if model.assets.isEmpty {
                Text("The photos you select show along the bottom.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var rangeGrid: some View {
        Group {
            if model.state == .loading {
                ProgressView("Finding photos…").frame(maxWidth: .infinity, minHeight: 180)
            } else if model.assets.isEmpty {
                ContentUnavailableView("No photos in this range", systemImage: "photo.on.rectangle.angled",
                                       description: Text("Choose another range, then find photos."))
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
        }
    }

    private var pickedStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(model.selectionOrder.enumerated()), id: \.element) { index, id in
                    if let asset = model.assets.first(where: { $0.localIdentifier == id }) {
                        AssetTile(asset: asset, ordinal: index + 1, total: model.selectionOrder.count,
                                  selected: model.selectedIDs.contains(id)) {
                            model.toggle(asset)
                        }
                        .frame(width: 72)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Selected photos")
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
        VStack(alignment: .leading, spacing: 12) {
            datePickers
            if model.state == .loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else if model.assets.isEmpty {
                // The range loaded (or failed) with nothing to show; offer a manual retry
                // instead of a "Find photos" button that would otherwise sit on every load.
                Button {
                    Task { await model.loadAssets() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(model.state == .importing)
            }
        }
        .padding(14)
        .ak14Card()
        .onChange(of: model.startDate) { _, _ in Task { await model.loadAssets() } }
        .onChange(of: model.endDate) { _, _ in Task { await model.loadAssets() } }
    }

    private var selectionHeader: some View {
        Text("\(model.selectedIDs.count) photos selected")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("selectionCount")
    }

    private var photoFooter: some View {
        VStack(spacing: 0) {
            if model.exactSet, !model.selectionOrder.isEmpty {
                pickedStrip
                    .background(Color.black)
            }
            if model.state == .importing {
                HStack(spacing: 12) {
                    designerPill("Keep processing images")
                    Button("Cancel", role: .cancel) { importTask?.cancel() }
                        .accessibilityHint("Stops after the photo currently being copied")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Color.black)
            } else if let failure = model.failureMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(failure, systemImage: "exclamationmark.icloud")
                        .font(.footnote).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry import") {
                        importTask = Task { if await model.retry() { path.append(.review) } }
                    }
                    .buttonStyle(.glassProminent)
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
                .buttonStyle(.glassProminent)
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
                    Text("Continue with \(model.selectedIDs.count) photos")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(model.selectedIDs.isEmpty || model.state == .loading || model.state == .requestingAccess)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Color.black)
                .accessibilityHint("Copies the selected originals to prepare them for review")
            }
        }
    }

    private func designerPill(_ title: String, label: String? = nil) -> some View {
        HStack(spacing: 8) {
            if title == "Keep processing images" {
                ProgressView().controlSize(.small).tint(.black)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .accessibilityLabel(label ?? title)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AK14Palette.field, in: Capsule())
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var reviewStage: some View {
        Group {
            if model.isGenerating {
                generatingView
            } else {
                reviewContent
            }
        }
        .background(AppBackdrop())
        .containerBackground(Color.black, for: .navigation)
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) { if !model.isGenerating { reviewFooter } }
    }

    /// A full-screen state so a long generation never leaves the owner staring at the Review
    /// screen with only a small pill for feedback. Shows a blurred collage of the chosen photos,
    /// the current stage, a determinate bar when the stage message reports "N of M", and Cancel.
    private var generatingView: some View {
        ZStack {
            generatingBackdrop
            VStack(spacing: 18) {
                Spacer()
                Text(model.progressMessage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .accessibilityIdentifier("generatingStageLabel")
                if let fraction = Self.progressFraction(from: model.progressMessage) {
                    ProgressView(value: fraction)
                        .tint(AK14Palette.accent)
                        .frame(width: 220)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
                Spacer()
                Button("Cancel", role: .cancel) { generateTask?.cancel() }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .padding(.bottom, 24)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("generatingStage")
    }

    private var generatingBackdrop: some View {
        ZStack {
            Color.black
            if let folder = model.importedFolder, let first = model.records.first {
                ImportedThumbnail(record: first, folder: folder, side: 900, cornerRadius: 0)
                    .blur(radius: 44)
                    .overlay(Color.black.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// Parses a progress message such as "Rendering option 2 of 3" into a 0...1 fraction; nil
    /// when the message carries no such count, so the caller falls back to an indeterminate spinner.
    private static func progressFraction(from message: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+) of (\d+)"#),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let xRange = Range(match.range(at: 1), in: message),
              let yRange = Range(match.range(at: 2), in: message),
              let x = Double(message[xRange]), let y = Double(message[yRange]), y > 0
        else { return nil }
        return min(1, max(0, x / y))
    }

    private var reviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Review your selection")
                        .font(.title2.weight(.semibold))
                    Text(model.exactSet ? "All \(model.records.count) photos will be used" : "\(model.records.count) photos ready\(dateSummary.map { " · \($0)" } ?? "")")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("exactSetCount")
                }
                selectedPhotosSection

                if !model.exactSet && model.events.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choose an event").font(.headline)
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
                    .ak14Card()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("What was this?").font(.headline)
                    TextField("Munnar trip with my cousins — the misty hike is the highlight", text: $model.storyHint, axis: .vertical)
                        .lineLimit(3...6)
                        .focused($storyHintFocused)
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
                .ak14Card()

                aiStoryPlanningRow
            }
            .padding(18)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var selectedPhotosSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy(duration: 0.28)) { showAllPhotos.toggle() }
            } label: {
                HStack {
                    Text("Selected photos")
                        .font(.headline)
                    Spacer()
                    Text(showAllPhotos ? "Show less" : "See all")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: showAllPhotos ? "chevron.up" : "chevron.down")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(AK14Palette.cream)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Selected photos")
            if showAllPhotos, let folder = model.importedFolder {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8)], spacing: 8) {
                    ForEach(model.records) { record in
                        ImportedThumbnail(record: record, folder: folder, side: 108)
                    }
                }
            } else if let folder = model.importedFolder {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(model.records.prefix(12)) { record in
                            ImportedThumbnail(record: record, folder: folder, side: 84)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .frame(height: 88)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ak14Card()
    }

    private var localModeExplanation: some View {
        Text("Create a photos-only story using on-device photo analysis and layout. No thumbnails or descriptions are sent to a model.")
            .font(.footnote).foregroundStyle(.secondary)
    }

    /// A single compact row that states the real state ("On", "Off", "Needs setup") and opens a
    /// sheet with the privacy explanation, the toggle and the invite setup. Nothing else on the
    /// Review screen competes with "Create options".
    private var aiStoryPlanningRow: some View {
        Button { model.showWorkerSettings = true } label: {
            HStack {
                Label("AI story planning", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(aiStatusLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ak14Card()
        .accessibilityLabel("AI story planning, \(aiStatusLabel)")
        .accessibilityHint("Opens privacy details and setup")
    }

    private var aiStatusLabel: String {
        guard model.modelAssist else { return "Off" }
        return model.hasWorkerConfig ? "On" : "Needs setup"
    }

    @MainActor private func importIncomingBatch() async {
        guard path.isEmpty, !isImportingIncomingBatch else { return }
        isImportingIncomingBatch = true
        defer { isImportingIncomingBatch = false }
        #if DEBUG
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.ak14.app")
            ?? ((try? StoryPipeline.applicationSupport())?.appending(path: "SharedAppGroup", directoryHint: .isDirectory))
        #else
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.ak14.app")
        #endif
        guard let container else { return }
        let incoming = container.appending(path: "incoming", directoryHint: .isDirectory)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--seed-incoming-batch"), !didSeedIncomingBatch {
            didSeedIncomingBatch = true
            try? FileManager.default.removeItem(at: incoming)
            // Exercise recovery from an extension interrupted between its first photo and its
            // atomic order manifest. The importer must continue to the complete batch below.
            let interrupted = incoming.appending(path: "000-interrupted", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)
            try? Data([0x00]).write(to: interrupted.appending(path: "photo-0000.jpg"))
            let batch = incoming.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
            var names: [String] = []
            for index in 0..<3 {
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128))
                let color = [UIColor.systemBlue, .systemOrange, .systemGreen][index]
                let data = renderer.jpegData(withCompressionQuality: 0.9) { context in
                    color.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
                    UIColor.white.setFill(); context.cgContext.fill(CGRect(x: 20 + index * 12, y: 20, width: 45, height: 70))
                }
                let name = String(format: "photo-%04d.jpg", index)
                try? data.write(to: batch.appending(path: name)); names.append(name)
            }
            try? JSONEncoder().encode(names).write(to: batch.appending(path: "order.json"))
        }
        #endif
        // Share extensions can be interrupted while copying providers. Ignore batches until their
        // atomic order manifest exists and every listed file has landed; an incomplete first
        // directory must not prevent recovery of a later, complete share.
        let batches = ((try? FileManager.default.contentsOfDirectory(at: incoming, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let fm = FileManager.default
        let readyBatch = batches.first { batch in
            guard (try? batch.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let data = try? Data(contentsOf: batch.appending(path: "order.json")),
                  let names = try? JSONDecoder().decode([String].self, from: data), !names.isEmpty else { return false }
            return names.allSatisfy { name in
                guard !name.isEmpty, name != "order.json", URL(fileURLWithPath: name).lastPathComponent == name else { return false }
                var isDirectory: ObjCBool = false
                return fm.fileExists(atPath: batch.appending(path: name).path, isDirectory: &isDirectory) && !isDirectory.boolValue
            }
        }
        guard let batch = readyBatch,
              let data = try? Data(contentsOf: batch.appending(path: "order.json")),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return }
        do {
            let root = try StoryPipeline.applicationSupport().appending(path: "imports", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, name) in names.enumerated() {
                let ext = URL(fileURLWithPath: name).pathExtension
                try FileManager.default.copyItem(at: batch.appending(path: name), to: folder.appending(path: String(format: "photo-%04d.%@", index, ext)))
            }
            let result = try await FolderIngester().ingest(folder: folder, options: IngestOptions())
            if let old = model.importedFolder, !model.retainedSourceFolders.contains(old) {
                try? fm.removeItem(at: old)
            }
            model.importedFolder = folder
            model.records = result.photos.sorted { ($0.sourceRelativePaths.first ?? "") < ($1.sourceRelativePaths.first ?? "") }
            model.events = []; model.selectedEventIndex = nil
            model.exactSet = true; model.keepOrder = true; model.state = .ready; model.storyHint = ""
            model.occasionSplitResult = nil; model.options = []; model.selectedOptionID = nil
            try? fm.removeItem(at: batch)
            path = [.review]
        } catch { model.alert = .init(title: "Could not import shared photos", message: error.localizedDescription) }
    }

    private var reviewFooter: some View {
        VStack(spacing: 0) {
            if model.isPreparingOccasions {
                designerPill("Keep processing images")
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                    .accessibilityLabel("Generation progress: Keep processing images")
            }
            if let failure = model.failureMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry generation") {
                        generateTask = Task { if await model.retry() { path.append(.options) } }
                    }
                    .buttonStyle(.glassProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.vertical, 12)
            } else {
                Button {
                    storyHintFocused = false
                    generateTask = Task {
                        if await model.generateOptions() { path.append(.options) }
                    }
                } label: {
                    Text("Create options").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).controlSize(.large)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Color.black)
                .disabled(model.isPreparingOccasions)
            }
        }
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
                Section {
                    Label("Your originals stay on this device.", systemImage: "lock.shield")
                        .font(.subheadline.weight(.semibold))
                    Toggle("Use AI-assisted story planning", isOn: $model.modelAssist)
                        .accessibilityHint("When on, selected thumbnails and short descriptions are sent to the configured Worker. Full-resolution originals stay on this device.")
                    if model.modelAssist {
                        Text("AI planning sends selected small thumbnails and short descriptions to the AK14 Worker and OpenAI. Full-resolution originals stay on this device.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        localModeExplanation
                    }
                }
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
                         ? "AI-assisted planning is available. Creating options sends selected small thumbnails and short descriptions to the AK14 Worker and OpenAI. Full-resolution originals stay on this device."
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
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .preferredColorScheme(.dark)
            .presentationBackground(Color.black)
            .navigationTitle("Story settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.showWorkerSettings = false
                        guard model.modelAssist, model.hasWorkerConfig, !model.records.isEmpty else { return }
                        model.isPreparingOccasions = true
                        Task { await model.prepareOccasionChoices(useModel: true) }
                    }
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

private struct AppBackdrop: View {
    var body: some View {
        Color.black.ignoresSafeArea()
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
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, selected ? Color.accentColor : .white.opacity(0.7))
                        .symbolEffect(.bounce, value: selected)
                        .padding(5)
                        .glassEffect(.regular.tint(AK14Palette.pine.opacity(0.35)).interactive(), in: Circle())
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
    var side: CGFloat = 116
    var cornerRadius: CGFloat = 12
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Rectangle().fill(Color.white.opacity(0.08)).overlay(ProgressView()) }
        }
        .frame(width: side, height: side).clipped().clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
    /// One EditorModel per option, kept alive for the whole session on this screen so switching
    /// back to a previously-opened option reuses it instead of re-rendering from scratch.
    @State private var editorModels: [String: EditorModel] = [:]
    @State private var exportBusy = false
    @State private var shareURLs: [URL] = []
    @State private var sharePresented = false
    @State private var shareExport: (editor: EditorModel, document: CanvasDocument, revision: Int)?
    @State private var retryingGeneration = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var option: StoryOption? { model.selectedOption }
    private var editorKey: String? {
        option.map { $0.runDirectory.path + "/" + $0.id }
    }
    private var currentEditorModel: EditorModel? {
        guard let editorKey else { return nil }
        return editorModels[editorKey]
    }
    private var showFallbackBanner: Bool {
        guard let option else { return false }
        return option.modelAssistRequested && option.generationMode == .photosOnly
    }

    var body: some View {
        VStack(spacing: 8) {
            Text("Choose an option")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
            optionPicker
            if showFallbackBanner { fallbackBanner }
            if let option {
                if let editorModel = currentEditorModel {
                    CanvasEditorView(model: editorModel).id(editorKey)
                } else {
                    ProgressView("Opening…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("No options available", systemImage: "photo.stack", description: Text("Create a story to swipe through its slides."))
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppBackdrop())
        .containerBackground(Color.black, for: .navigation)
        .navigationTitle("Options")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .overlay(alignment: .topLeading) {
            if let option {
                Text(option.runDirectory.appending(path: "interaction-events.jsonl").path)
                    .font(.system(size: 1)).foregroundStyle(.clear)
                    .accessibilityIdentifier("interactionLogPath")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 8) { actionFooter }
        .sheet(isPresented: $sharePresented) { ActivityShareSheet(items: shareURLs, onCompletion: shareFinished) }
        .sensoryFeedback(.success, trigger: model.successfulSaves)
        .onChange(of: editorKey) { old, _ in
            if let old, let previous = editorModels[old] { previous.flushSave() }
        }
        .task(id: editorKey) {
            guard let option, let editorKey else { return }
            model.presentOptions(for: option)
            guard editorModels[editorKey] == nil else { return }
            do { editorModels[editorKey] = try EditorModel(option: option, records: model.records) }
            catch { model.alert = .init(title: "Could not open design", message: error.localizedDescription) }
        }
        .onDisappear {
            for editorModel in editorModels.values { editorModel.flushSave() }
            if let option { model.leaveOptions(for: option) }
        }
    }

    private var fallbackBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("AI planning unavailable — this is a photos-only draft.")
                .font(.footnote)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if retryingGeneration {
                ProgressView().controlSize(.small)
            } else {
                Button("Try again") { Task { await retryGeneration() } }
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
    }

    private func retryGeneration() async {
        retryingGeneration = true
        defer { retryingGeneration = false }
        if await model.retry() {
            // New runs reuse IDs such as c1. Retain only the current run, and let the
            // run-qualified task above open its editor even when the option ID is unchanged.
            let root = model.selectedOption?.runDirectory
            editorModels = editorModels.filter { $0.value.option.runDirectory == root }
        }
    }

    private var optionPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(model.options.enumerated()), id: \.element.id) { index, candidate in
                    let selected = candidate.id == model.selectedOptionID
                    let title = candidate.title.isEmpty ? "Option \(index + 1)" : candidate.title
                    Button {
                        if reduceMotion { model.selectOption(candidate) }
                        else { withAnimation(.snappy(duration: 0.28)) { model.selectOption(candidate) } }
                    } label: {
                        VStack(spacing: 4) {
                            OptionCoverThumbnail(url: candidate.slides.first)
                                .frame(width: 64, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(selected ? AK14Palette.accent : Color.white.opacity(0.15), lineWidth: selected ? 2.5 : 1))
                            Text(title)
                                .font(.caption.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.7))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(exportBusy || retryingGeneration)
                    .accessibilityLabel("\(title), \(candidate.slides.count) slides")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    private func share() async {
        guard let editorModel = currentEditorModel else { return }
        exportBusy = true
        defer { exportBusy = false }
        do {
            let export = try await editorModel.exportRevision()
            shareExport = (editorModel, export.document, export.revision)
            shareURLs = export.urls
            sharePresented = true
        } catch { model.alert = .init(title: "Could not share design", message: error.localizedDescription) }
    }

    /// Completion is recorded only when the system reports the share succeeded, against the revision shared.
    private func shareFinished(_ activity: UIActivity.ActivityType?, _ completed: Bool) {
        defer { shareExport = nil }
        guard completed, let shared = shareExport else { return }
        let snapshot = try? shared.editor.handoffSnapshot(shared.document, revision: shared.revision)
        Task { await model.shareCompleted(for: shared.editor.option, activityType: activity, snapshot: snapshot) }
    }

    private func save() async {
        guard let editorModel = currentEditorModel, let option else { return }
        exportBusy = true
        defer { exportBusy = false }
        do {
            let export = try await editorModel.exportRevision()
            let snapshot = try? editorModel.handoffSnapshot(export.document, revision: export.revision)
            await model.save(export.urls, for: option, snapshot: snapshot)
        } catch { model.alert = .init(title: "Could not save design", message: error.localizedDescription) }
    }

    private var actionFooter: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button { Task { await save() } } label: {
                    if exportBusy { ProgressView().frame(maxWidth: .infinity) }
                    else { Label("Save", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.glassProminent)
                .disabled(currentEditorModel == nil || exportBusy)
                .accessibilityLabel("Save to Photos")
                Button { Task { await share() } } label: {
                    Image(systemName: "square.and.arrow.up")
                        .symbolEffect(.bounce, value: sharePresented)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .disabled(currentEditorModel == nil || exportBusy)
                .accessibilityLabel("Share slides")
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
        }
    }
}

/// A small cover thumbnail for an option card. Loads the option's already-rendered first slide
/// (never the editor's live preview), so switching options never triggers a render.
private struct OptionCoverThumbnail: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.white.opacity(0.08))
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            let path = url.path
            image = await Task.detached(priority: .utility) {
                EditorThumbnailLoader.load(path: path, maxPixel: 200).map(UIImage.init(cgImage:))
            }.value
        }
    }
}

private struct SystemPhotoPicker: UIViewControllerRepresentable {
    var onPicked: ([String]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 0
        config.selection = .ordered
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: ([String]) -> Void
        init(onPicked: @escaping ([String]) -> Void) { self.onPicked = onPicked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let identifiers = results.compactMap(\.assetIdentifier)
            picker.dismiss(animated: true) {
                if !identifiers.isEmpty { self.onPicked(identifiers) }
            }
        }
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
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
