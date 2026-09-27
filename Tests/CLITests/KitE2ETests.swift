import CoreGraphics
import Foundation
import Testing
@testable import Render

private func kitBytes(_ asset: KitAsset, seed: UInt64) -> Data {
    let width=220,height=150
    let bytesPerRow=width*4
    let data=NSMutableData(length:height*bytesPerRow)!
    let context=CGContext(data:data.mutableBytes,width:width,height:height,bitsPerComponent:8,bytesPerRow:bytesPerRow,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray:0.96,alpha:1)); context.fill(CGRect(x:0,y:0,width:width,height:height))
    asset.draw(in:context,rect:CGRect(x:10,y:10,width:200,height:130),seed:seed)
    return Data(bytes: data.mutableBytes, count: data.length)
}

@Test func kitRegistryMatchesManifestAndRendersDeterministically() throws {
    let manifestURL=Bundle.module.url(forResource:"manifest",withExtension:"json",subdirectory:"Assets")!
    let root=try JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as! [String:Any]
    let rows=root["assets"] as! [[String:Any]]
    let kitRows=rows.filter { $0["assetType"] as? String == "procedural" && $0["author"] as? String == "AK14" }
    let manifestIDs=Set(kitRows.compactMap{$0["assetID"] as? String})
    let registryIDs=Set(KitAssetRegistry.all.map(\.id))
    #expect(registryIDs.count >= 60)
    #expect(registryIDs.isSubset(of:manifestIDs))
    #expect(manifestIDs == registryIDs)
    for asset in KitAssetRegistry.all {
        #expect(kitBytes(asset,seed:741)==kitBytes(asset,seed:741),"\(asset.id) is not byte deterministic")
    }
    let organic=KitAssetRegistry.all.filter{[.tape,.tornEdge].contains($0.category)}
    #expect(organic.contains{kitBytes($0,seed:1) != kitBytes($0,seed:2)},"seeded edges should vary")
    try KitPreview.renderSheet(to:URL(fileURLWithPath:"/tmp/ak14-kit-preview.png"))
    #expect(FileManager.default.fileExists(atPath:"/tmp/ak14-kit-preview.png"))
}
