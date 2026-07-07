import SwiftUI

struct ProductEmptyState: View {
    var title: String
    var systemImageName: String
    var message: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImageName,
            description: Text(message)
        )
    }
}
