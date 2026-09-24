import Foundation

/// R6: the cheapest graph that reports steps - no model, no download. EmptyImage batches
/// run through ColorTransfer, whose per-frame loop calls comfy.utils.ProgressBar
/// (comfy_extras/nodes_post_processing.py:854), so ComfyUI emits "progress" with
/// value/max per frame. One frame is saved: the calibration file, under
/// <output>/comfybar_calibration/. Never queued on 8188 (guarded at the call site).
enum Calibration {
    static let prefix = "comfybar_calibration/calib"

    /// `frames` per stage, `stages` ColorTransfer nodes in series (each reports its own
    /// 1...frames progress), so a run lasts roughly stages x the single-stage time.
    static func graph(frames: Int, stages: Int, size: Int = 512, seed: Int) -> [String: Any] {
        var g: [String: Any] = [
            "src": ["class_type": "EmptyImage",
                    "inputs": ["width": size, "height": size, "batch_size": frames, "color": seed & 0xFFFFFF]],
            "ref": ["class_type": "EmptyImage",
                    "inputs": ["width": size, "height": size, "batch_size": 1, "color": 0xCC8844]],
        ]
        var last = "src"
        for i in 1...max(1, stages) {
            let id = "ct\(i)"
            g[id] = ["class_type": "ColorTransfer",
                     "inputs": ["image_target": [last, 0], "image_ref": ["ref", 0], "method": "mkl_lab",
                                "source_stats": "per_frame", "strength": 1.0 - Double(i) * 0.01]]
            last = id
        }
        g["pick"] = ["class_type": "ImageFromBatch", "inputs": ["image": [last, 0], "batch_index": 0, "length": 1]]
        g["save"] = ["class_type": "SaveImage", "inputs": ["images": ["pick", 0], "filename_prefix": prefix]]
        return g
    }
}
