import Core

/// Chooses a curated render treatment from the direction's existing visual axes.
/// The photos-only control deliberately stays free of overlays.
public enum RecipeSelection {
    public static func recipe(for plan: CarouselPlan, in stylePack: StylePack) -> Recipe? {
        guard !plan.isBaseline, let style = plan.direction?.style.normalized,
              let recipes = stylePack.recipes else { return nil }
        let family: Recipe.Family
        if style.decoration == "rich" || style.grouping == "collage" {
            family = .scrapbook
        } else if style.whitespace == "airy" {
            family = .journal
        } else {
            family = .minimal
        }
        return recipes.first(where: { $0.family == family })
    }
}
