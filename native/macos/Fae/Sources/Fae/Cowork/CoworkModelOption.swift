import Foundation

struct CoworkModelOption: Identifiable, Hashable, Sendable {
    let modelIdentifier: String
    let routeLabel: String
    let vendorLabel: String
    let compactLabel: String
    let vendorModelLabel: String
    let vendorModelLabelWithRoute: String
    let searchText: String

    var id: String { modelIdentifier }
}
