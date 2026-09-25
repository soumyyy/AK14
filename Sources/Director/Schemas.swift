import Core

/// Strict JSON schemas. Candidate IDs and decoration IDs are enums so the model cannot invent them.
enum Schemas {
    static let triageTags = ["people", "group", "selfie", "food", "drink", "sign", "text", "venue", "detail", "landscape",
                             "architecture", "night", "flash", "motion", "mirror", "animal", "vehicle", "nature", "celebration"]

    static func triage(ids: [AssetID]) -> JSONValue {
        .obj([("results", .arr(.obj([
            ("id", .str(ids.map(\.rawValue))),
            ("emotionalValue", .integer(0, 5)),
            ("imperfection", .str(["useful", "neutral", "accident"])),
            ("safety", .arr(.str(["blink", "unflattering", "awkwardCrop", "sensitive"]))),
            ("tags", .arr(.str(triageTags))),
            ("confidence", .str(["low", "medium", "high"])),
        ])))])
    }

    static func planner(ids: [AssetID], decorationIDs: [String]) -> JSONValue {
        let id = JSONValue.str(ids.map(\.rawValue))
        let photo = JSONValue.obj([
            ("assetID", id),
            ("role", .str(["hero", "support", "detail"])),
            ("importance", .integer(1, 3)),
            ("cropIntent", .str(["tight", "balanced", "loose"])),
            ("anchorIntent", .str(["center", "top", "bottom", "left", "right"])),
            ("overlapIntent", .str(["none", "slight", "strong"])),
            ("rotationIntent", .str(["none", "slightLeft", "slightRight"])),
        ])
        let slide = JSONValue.obj([
            ("primitive", .str(Primitive.allCases.map(\.rawValue))),
            ("mood", .str(["calm", "warm", "energetic", "nostalgic", "playful", "moody"])),
            ("density", .str(["quiet", "balanced", "dense"])),
            ("photos", .arr(photo, min: 1, max: 4)),
            ("decorations", .arr(.obj([("decorationID", .str(decorationIDs)), ("intensity", .str(["low", "medium", "high"]))]))),
            ("stamps", .arr(.obj([("kind", .str(["date", "location"])),
                                  ("placement", .str(["topLeft", "topRight", "bottomLeft", "bottomRight"]))]))),
        ])
        return .obj([
            ("recommendedSlideCount", .integer(1, 20)),
            ("spine", .obj([
                ("orderedAssetIDs", .arr(id, min: 1, max: 20)),
                ("sequenceIntent", .arr(.str(SequenceIntent.allCases.map(\.rawValue)))),
                ("rationale", .arr(.obj([("id", id), ("reason", .str(["cover", "emotional", "story", "variety", "detail", "people", "place"]))]))),
            ])),
            ("plans", .arr(.obj([
                ("conceptType", .str(ConceptType.allCases.map(\.rawValue))),
                ("conceptNote", .str()),
                ("slides", .arr(slide, min: 1, max: 20)),
            ]), min: 3, max: 3)),
        ])
    }
}
