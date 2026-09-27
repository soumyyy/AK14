import SwiftUI

@main
struct AK14App: App {
    var body: some Scene {
        WindowGroup {
            ImportReviewView()
                .preferredColorScheme(.dark)
                .background(Color.black.ignoresSafeArea())
        }
    }
}
