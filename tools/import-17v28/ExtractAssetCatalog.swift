import AppKit
import Foundation

// Reads an asset catalog with the system's private CoreUI reader and writes selected images as PNG.
let args = CommandLine.arguments
let carURL = URL(fileURLWithPath: args[1]), outDir = URL(fileURLWithPath: args[2])
let prefixes = Array(args.dropFirst(3))
guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/CoreUI.framework"), bundle.load(),
      let cls = NSClassFromString("CUICatalog") as? NSObject.Type else { fatalError("CoreUI unavailable") }
let alloc = cls.perform(NSSelectorFromString("alloc")).takeUnretainedValue() as! NSObject
typealias InitURL = @convention(c) (AnyObject, Selector, NSURL, UnsafeMutablePointer<NSError?>?) -> Unmanaged<AnyObject>?
let sel = NSSelectorFromString("initWithURL:error:")
let imp = alloc.method(for: sel)
let initFn = unsafeBitCast(imp, to: InitURL.self)
guard let catalog = initFn(alloc, sel, carURL as NSURL, nil)?.takeRetainedValue() as? NSObject else { fatalError("cannot open catalog") }
let names = (catalog.value(forKey: "allImageNames") as? [String]) ?? []
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
var written = 0
for name in names where prefixes.contains(where: { name.hasPrefix($0) }) {
    guard let images = catalog.perform(NSSelectorFromString("imagesWithName:"), with: name)?.takeUnretainedValue() as? [NSObject] else { continue }
    // Keep the largest rendition.
    var best: CGImage?
    for img in images {
        if let unmanaged = img.perform(NSSelectorFromString("image")) {
            let cg = unmanaged.takeUnretainedValue() as! CGImage
            if best == nil || cg.width > best!.width { best = cg }
        }
    }
    guard let cg = best else { continue }
    let rep = NSBitmapImageRep(cgImage: cg)
    if let data = rep.representation(using: .png, properties: [:]) {
        try data.write(to: outDir.appending(path: "\(name).png")); written += 1
    }
}
print("wrote \(written) of \(names.count) names")
