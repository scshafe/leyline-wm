import ApplicationServices
import CoreGraphics
import Foundation
import LeylineModel

/// Real local CoreFoundation/AXValue payloads exercise the exact live decoder; no AX IPC or setters.
func runProjectionWindowAttributeBatchScenarios(test: inout SelfTest) {
    var point = CGPoint(x: 20, y: 30), size = CGSize(width: 916, height: 600)
    guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size) else {
        test.check(false, "attribute-batch/local-AXValue-fixture"); return
    }
    let complete: [AnyObject] = [p, s, "AXWindow" as NSString, "AXStandardWindow" as NSString, kCFBooleanFalse, "Safari" as NSString]
    func decoded(_ values: [AnyObject]) -> Result<ProjectionWindowAttributeBatch, ProjectionObservationFailure> {
        projectionDecodeWindowAttributes(values as CFArray)
    }
    func reason(_ result: Result<ProjectionWindowAttributeBatch, ProjectionObservationFailure>) -> String? {
        if case .failure(let failure) = result { return failure.code }; return nil
    }
    let valid = decoded(complete)
    test.check({ if case .success(let value) = valid { return value.frame == Frame(x: 20, y: 30, w: 916, h: 600)
        && value.role == "AXWindow" && value.subrole == "AXStandardWindow" && !value.minimized && value.title == "Safari" }; return false }(),
        "attribute-batch/six-real-CF-values-decode-exact-frame-and-mandatory-types")
    test.check(reason(projectionDecodeWindowAttributes(nil)) == "ax_attribute_batch_malformed"
        && reason(decoded(Array(complete.dropLast()))) == "ax_attribute_batch_malformed"
        && reason(decoded(complete + ["extra" as NSString])) == "ax_attribute_batch_malformed",
        "attribute-batch/nil-short-and-extra-arrays-refuse")
    for index in complete.indices {
        for error in [AXError.noValue, .attributeUnsupported, .cannotComplete, .failure] {
            var rawError = error
            guard let slot = AXValueCreate(.axError, &rawError) else { test.check(false, "attribute-batch/error-AXValue-create"); continue }
            var values = complete; values[index] = slot
            let result = decoded(values)
            if index == 5 && error == .noValue {
                test.check({ if case .success(let value) = result { return value.title.isEmpty }; return false }(),
                    "attribute-batch/title-noValue-is-the-only-legitimate-absent-slot")
            } else {
                test.check(reason(result) == "ax_attribute_read_failed:\(projectionWindowReadAttributes()[index]):\(error.rawValue)",
                    "attribute-batch/slot-\(index)-error-\(error.rawValue)-is-typed-failure")
            }
        }
    }
    for (name, index, replacement) in [("null-position", 0, kCFNull as AnyObject),
        ("wrong-role", 2, NSNumber(value: 1) as AnyObject), ("numeric-minimized", 4, NSNumber(value: 1) as AnyObject),
        ("null-title", 5, kCFNull as AnyObject), ("wrong-title", 5, NSNumber(value: 1) as AnyObject)] {
        var values = complete; values[index] = replacement
        test.check(reason(decoded(values)) == "ax_attribute_type_mismatch", "attribute-batch/\(name)-refuses-malformed-mandatory-value")
    }
    var swapped = complete; swapped[0] = s; swapped[1] = p
    test.check(reason(decoded(swapped)) == "ax_frame_read_failed", "attribute-batch/swapped-AXValue-geometry-types-refuse")
    var invalidPoint = CGPoint(x: CGFloat.infinity, y: 30)
    guard let invalid = AXValueCreate(.cgPoint, &invalidPoint) else { test.check(false, "attribute-batch/nonfinite-AXValue-create"); return }
    var nonfinite = complete; nonfinite[0] = invalid
    test.check(reason(decoded(nonfinite)) == "ax_frame_read_failed", "attribute-batch/nonfinite-frame-refuses")
}
