import CoreGraphics
import Foundation

public enum KitAssetRegistry {
    private static let definitions: [(String, KitCategory, CGFloat, CGFloat, Bool)] = [
        ("tape-washi-cream",.tape,180,34,false),("tape-washi-sage",.tape,180,34,false),("tape-washi-rose",.tape,180,34,false),("tape-masking",.tape,180,34,false),("tape-grid",.tape,180,34,false),("tape-dot",.tape,180,34,false),
        ("paper-kraft",.paper,120,150,false),("paper-lined",.paper,120,150,false),("paper-ledger",.paper,120,150,false),("paper-newsprint",.paper,120,150,false),("paper-cotton",.paper,120,150,false),
        ("torn-edge-soft",.tornEdge,180,40,false),("torn-edge-rough",.tornEdge,180,40,false),("torn-edge-paper",.tornEdge,180,40,false),("torn-edge-double",.tornEdge,180,40,false),
        ("film-frame-35mm",.filmFrame,180,112,false),("film-frame-contact",.filmFrame,180,112,false),("film-frame-negative",.filmFrame,180,112,false),
        ("instant-frame-classic",.instantFrame,120,150,false),("instant-frame-wide",.instantFrame,180,130,false),("instant-frame-mini",.instantFrame,100,125,false),
        ("doodle-star",.doodle,64,64,true),("doodle-heart",.doodle,64,64,true),("doodle-arrow",.doodle,100,54,true),("doodle-underline",.doodle,120,28,true),("doodle-circle-scribble",.doodle,72,72,true),("doodle-sparkle",.doodle,60,60,true),
        ("label-blank",.label,120,44,false),("label-rounded",.label,120,44,false),("label-ticket",.label,120,54,false),("label-date",.label,110,38,false),("label-caption",.label,130,42,false),
        ("light-leak-amber",.lightLeak,180,120,false),("light-leak-coral",.lightLeak,180,120,false),("light-leak-violet",.lightLeak,180,120,false),("light-leak-edge",.lightLeak,180,120,false),
        ("grain-fine",.grain,128,128,false),("grain-medium",.grain,128,128,false),("grain-heavy",.grain,128,128,false),("grain-35mm",.grain,128,128,false),("grain-soft",.grain,128,128,false),
        ("dust-sparse",.dust,128,128,false),("dust-film",.dust,128,128,false),("dust-scratches",.dust,128,128,false),("dust-flecks",.dust,128,128,false),
        ("shape-star",.shape,64,64,true),("shape-heart",.shape,64,64,true),("shape-circle",.shape,64,64,true),("shape-pill",.shape,100,44,true),("shape-sun",.shape,72,72,true),
        ("tape-washi-blue",.tape,180,34,false),("tape-washi-lilac",.tape,180,34,false),("tape-crosshatch",.tape,180,34,false),("paper-blue",.paper,120,150,false),("paper-blush",.paper,120,150,false),("torn-edge-deckle",.tornEdge,180,40,false),("film-frame-portrait",.filmFrame,112,180,false),("instant-frame-square",.instantFrame,140,140,false),("label-postmark",.label,110,50,false),("light-leak-gold",.lightLeak,180,120,false),("grain-chunky",.grain,128,128,false),("dust-hairline",.dust,128,128,false),("shape-diamond",.shape,64,64,true),("paper-warm",.paper,120,150,false),("tape-clear",.tape,180,34,false),("film-edge",.filmFrame,180,112,false)
    ]
    public static let all: [KitAsset] = definitions.map { KitAsset(id:$0.0,category:$0.1,defaultSize:CGSize(width:$0.2,height:$0.3),tintable:$0.4) }
    public static func asset(id: String) -> KitAsset? { all.first { $0.id == id } }
}
