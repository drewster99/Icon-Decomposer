import Foundation

/// Represents the type of data flowing through the pipeline
public enum DataType: Equatable {
    case none
    case rgbaImage
    case labImage
    case superpixelFeatures
    case clusterAssignments
    case layers

    /// Check if this type can be used as input for another type
    func canFeedInto(_ other: DataType) -> Bool {
        switch (self, other) {
        case (.rgbaImage, .labImage),
             (.labImage, .superpixelFeatures),
             (.superpixelFeatures, .clusterAssignments),
             (.clusterAssignments, .layers):
            return true
        default:
            return false
        }
    }
}
