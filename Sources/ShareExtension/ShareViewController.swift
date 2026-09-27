import Photos
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        let label = UILabel()
        label.text = "Preparing photos…"
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24), label.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        Task { await saveImages(label: label) }
    }

    @MainActor private func saveImages(label: UILabel) async {
        let providers = (extensionContext?.inputItems as? [ NSExtensionItem ] ?? []).flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }.prefix(50)
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.ak14.app") else {
            label.text = "Could not prepare photos. Open AK14 and try again."; return
        }
        let batch = container.appendingPathComponent("incoming", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
            var names: [String] = []
            for (index, provider) in providers.enumerated() {
                if let (data, ext) = try await loadImage(provider) {
                    let name = String(format: "photo-%04d.%@", index, ext)
                    try data.write(to: batch.appendingPathComponent(name), options: .atomic)
                    names.append(name)
                }
            }
            guard !names.isEmpty else { throw CocoaError(.fileReadUnknown) }
            try JSONEncoder().encode(names).write(to: batch.appendingPathComponent("order.json"), options: .atomic)
            label.text = "Added \(names.count) photos. Open AK14 to create your carousel."
            let button = UIButton(type: .system)
            button.setTitle("Done", for: .normal)
            button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            button.addTarget(self, action: #selector(done), for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(button)
            NSLayoutConstraint.activate([button.centerXAnchor.constraint(equalTo: view.centerXAnchor), button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 20)])
        } catch {
            // Leave no partial directory that could be mistaken for a completed handoff.
            try? FileManager.default.removeItem(at: batch)
            label.text = "Could not prepare photos. Open AK14 and try again."
        }
    }

    private func loadImage(_ provider: NSItemProvider) async throws -> (Data, String)? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                if let error { continuation.resume(throwing: error) }
                else if let data {
                    let ext = provider.registeredTypeIdentifiers.compactMap { UTType($0)?.preferredFilenameExtension }.first ?? "jpg"
                    continuation.resume(returning: (data, ext))
                } else { continuation.resume(returning: nil) }
            }
        }
    }

    @objc private func done() { extensionContext?.completeRequest(returningItems: nil) }
}
