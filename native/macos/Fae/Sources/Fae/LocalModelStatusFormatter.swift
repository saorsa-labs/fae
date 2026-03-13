import Foundation

struct LocalModelStatusFormatter {
    static func shortModelName(_ modelId: String) -> String {
        modelId.components(separatedBy: "/").last ?? modelId
    }

    static func conciergeLabel(
        plan: FaeConfig.LocalModelStackPlan,
        loadedConciergeModelId: String?,
        conciergeLoaded: Bool,
        conciergeRuntime: String?,
        conciergeWorkerLastError: String?
    ) -> String? {
        guard plan.dualModelActive, let plannedModelId = plan.conciergeModel?.modelId else {
            return nil
        }

        if conciergeLoaded, let loadedConciergeModelId {
            return shortModelName(loadedConciergeModelId)
        }

        let plannedName = shortModelName(plannedModelId)
        if let conciergeWorkerLastError,
           !conciergeWorkerLastError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return "\(plannedName) (error)"
        }

        if conciergeRuntime == "worker_process" {
            return "\(plannedName) (loading...)"
        }

        return plannedName
    }

    static func stackSummary(
        plan: FaeConfig.LocalModelStackPlan,
        loadedOperatorModelId: String?,
        loadedConciergeModelId: String?,
        conciergeLoaded: Bool,
        conciergeRuntime: String?,
        conciergeWorkerLastError: String?
    ) -> String {
        let operatorModelId = loadedOperatorModelId ?? plan.operatorModel.modelId
        let operatorName = shortModelName(operatorModelId)

        guard let conciergeLabel = conciergeLabel(
            plan: plan,
            loadedConciergeModelId: loadedConciergeModelId,
            conciergeLoaded: conciergeLoaded,
            conciergeRuntime: conciergeRuntime,
            conciergeWorkerLastError: conciergeWorkerLastError
        ) else {
            return operatorName
        }

        return "Operator: \(operatorName) · Concierge: \(conciergeLabel)"
    }
}
