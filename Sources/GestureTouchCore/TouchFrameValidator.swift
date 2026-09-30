import Foundation

public enum TouchFrameValidator {
    public static func isValid(_ touches: [ActiveTouch]) -> Bool {
        guard touches.count <= 20 else { return false }
        var identifiers = Set<Int>()
        return touches.allSatisfy {
            (-1...128).contains($0.identifier) && identifiers.insert($0.identifier).inserted
                && $0.normalizedX.isFinite && $0.normalizedY.isFinite
                && (-0.2...1.2).contains($0.normalizedX) && (-0.2...1.2).contains($0.normalizedY)
        }
    }
}
