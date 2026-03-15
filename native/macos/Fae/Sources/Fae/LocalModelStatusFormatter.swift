import Foundation

struct LocalModelStatusFormatter {
    static func shortModelName(_ modelId: String) -> String {
        modelId.components(separatedBy: "/").last ?? modelId
    }

    static func stackSummary(loadedModelId: String?, preset: String) -> String {
        if let loadedModelId {
            return shortModelName(loadedModelId)
        }
        let recommended = FaeConfig.recommendedModel(preset: preset)
        return shortModelName(recommended.modelId)
    }
}
