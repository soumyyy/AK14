import Core

/// Strict JSON schemas. Candidate IDs and decoration IDs are enums so the model cannot invent them.
enum Schemas {
    static let triageTags = ["people", "group", "selfie", "food", "drink", "sign", "text", "venue", "detail", "landscape",
                             "architecture", "night", "flash", "motion", "mirror", "animal", "vehicle", "nature", "celebration",
                             "candid", "characterful", "gesture", "portrait", "personality"]

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

    static func planner(ids: [AssetID]) -> JSONValue {
        let id = JSONValue.str(ids.map(\.rawValue))
        let style = JSONValue.obj(StyleVector.axes.map { ($0.name, JSONValue.str($0.values)) })
        let direction = JSONValue.obj([
            ("brief", .str()),
            ("style", style),
            ("coverAssetID", id),
            ("orderedAssetIDs", .arr(id, min: 1, max: 20)),
            ("keepTogether", .arr(.arr(id, min: 2, max: 4))),
            ("emphasisAssetIDs", .arr(id)),
        ])
        return .obj([
            ("recommendedSlideCount", .integer(1, 20)),
            ("spine", .obj([
                ("orderedAssetIDs", .arr(id, min: 1, max: 20)),
                ("sequenceIntent", .arr(.str(SequenceIntent.allCases.map(\.rawValue)))),
                ("rationale", .arr(.obj([("id", id), ("reason", .str(["cover", "emotional", "story", "variety", "detail", "people", "place"]))]))),
                ("transitionReasons", .arr(.obj([("from", id), ("to", id), ("reason", .str())]))),
            ])),
            ("directions", .arr(direction, min: 2, max: 5)),
        ])
    }
}
