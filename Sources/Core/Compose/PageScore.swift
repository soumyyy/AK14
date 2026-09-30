/// Every weight PageSearch uses. Higher total is better.
enum PageScore {
    static let authoredPage = 1.0, gridPage = 0.4
    static let authoredNeighbour = 0.3
    static let titledCover = 0.5
    static let storyRank = 0.2
    static let cropCost = 1.0
    static let repeatedPage = 1.0
    static let monotony = 0.6
    static let movedPhoto = 0.4
    static let whiteCard = 5.0
    static let whiteCardCover = 10.0
    static let blankRunMember = 0.3
    static let slideCountMiss = 0.5
    static let beamWidth = 48, pagesPerStep = 12, alternativesPerMoment = 6
}
