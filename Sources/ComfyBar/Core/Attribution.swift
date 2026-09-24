import Foundation

/// Who queued a job. ComfyUI does not record a client name, so this is inference from what
/// the queue item carries - and every answer carries the evidence it was drawn from.
enum JobSource: Equatable {
    /// The ComfyUI web page attaches its workflow as extra_data.extra_pnginfo.workflow.
    case comfyPage(evidence: String)
    /// ComfyBar's own calibration job (R6) - known by its client id.
    case comfyBar
    case otherClient(clientID: String)
    case noClientID

    var label: String {
        switch self {
        case .comfyPage: return "ComfyUI page"
        case .comfyBar: return "ComfyBar calibration"
        case .otherClient: return "another client"
        case .noClientID: return "a client that sent no client_id"
        }
    }

    var evidence: String {
        switch self {
        case .comfyPage(let e): return e
        case .comfyBar: return "ComfyBar's own client id"
        case .otherClient(let c): return "client_id \(c.prefix(8))…"
        case .noClientID: return "no client_id on the prompt"
        }
    }
}

enum Attribution {
    static func source(of item: QueueItem, comfyBarClientID: String?) -> JobSource {
        if let own = comfyBarClientID, item.clientID == own { return .comfyBar }
        if item.hasWorkflow { return .comfyPage(evidence: "workflow attached to the prompt") }
        if let c = item.clientID { return .otherClient(clientID: c) }
        return .noClientID
    }
}
