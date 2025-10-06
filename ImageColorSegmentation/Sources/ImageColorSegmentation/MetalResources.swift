//
//  MetalResources.swift
//  ImageColorSegmentation
//
//  Encapsulates Metal device and compiled shader library
//

import Foundation
import Metal

public enum MetalResourcesError: Error {
    case metalUnavailable
    case shaderLoadFailed(String)
}

/// Encapsulates Metal device and compiled shader library
public struct MetalResources {
    public let device: MTLDevice
    public let library: MTLLibrary

    // MARK: - Synchronous Initializer

    /// Create Metal resources with optional device and library
    /// Blocks thread during shader compilation (~350ms) if library not provided
    public init(device: MTLDevice? = nil, library: MTLLibrary? = nil) throws {
        // Resolve device
        if let device = device {
            self.device = device
        } else {
            guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
                throw MetalResourcesError.metalUnavailable
            }
            self.device = defaultDevice
        }

        // Resolve library
        if let library = library {
            self.library = library
        } else {
            // Try loading pre-compiled metallib first (from SPM package resources)
            if let library = try? Self.loadPrecompiledLibrary(device: self.device) {
                self.library = library
            } else {
                // Fall back to runtime compilation from source
                let slicSource = try Self.loadMetalShader(named: "SLIC")
                let kmeansSource = try Self.loadMetalShader(named: "KMeans")
                let combined = slicSource + "\n" + kmeansSource
                self.library = try self.device.makeLibrary(source: combined, options: nil)
            }
        }
    }

    // MARK: - Asynchronous Initializer

    /// Create Metal resources with optional device and library
    /// Doesn't block thread during shader compilation (~350ms) if library not provided
    public init(device: MTLDevice? = nil, library: MTLLibrary? = nil) async throws {
        // Resolve device
        if let device = device {
            self.device = device
        } else {
            guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
                throw MetalResourcesError.metalUnavailable
            }
            self.device = defaultDevice
        }

        // Resolve library
        if let library = library {
            self.library = library
        } else {
            // Try loading pre-compiled metallib first (from SPM package resources)
            if let library = try? Self.loadPrecompiledLibrary(device: self.device) {
                self.library = library
            } else {
                // Fall back to runtime compilation from source
                let slicSource = try Self.loadMetalShader(named: "SLIC")
                let kmeansSource = try Self.loadMetalShader(named: "KMeans")
                let combined = slicSource + "\n" + kmeansSource
                self.library = try await self.device.makeLibrary(source: combined, options: nil)
            }
        }
    }

    // MARK: - Shader Loading

    /// Load pre-compiled Metal library from bundle (for SPM package resources)
    private static func loadPrecompiledLibrary(device: MTLDevice) throws -> MTLLibrary? {
        // Try Bundle.module first (SPM)
        if let library = try? device.makeDefaultLibrary(bundle: Bundle.module) {
            return library
        }

        // Try all bundles for the default.metallib
        for bundle in Bundle.allBundles {
            if let library = try? device.makeDefaultLibrary(bundle: bundle) {
                return library
            }
        }

        return nil
    }

    /// Load Metal shader source from bundle with multi-location search for Xcode compatibility
    private static func loadMetalShader(named name: String) throws -> String {
        // Try Bundle.module first (SPM command line)
        if let url = Bundle.module.url(forResource: name, withExtension: "metal"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            return source
        }

        // Try Bundle.main (Xcode builds)
        if let url = Bundle.main.url(forResource: name, withExtension: "metal"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            return source
        }

        // Try all bundles as fallback
        for bundle in Bundle.allBundles {
            if let url = bundle.url(forResource: name, withExtension: "metal"),
               let source = try? String(contentsOf: url, encoding: .utf8) {
                return source
            }
        }

        throw MetalResourcesError.shaderLoadFailed("Shader '\(name).metal' not found in any bundle")
    }
}

// MARK: - Global Default Resources

/// Global default Metal resources (lazy initialized on first access)
let defaultResources = try! MetalResources()
