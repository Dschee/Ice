//
//  Package.swift
//  Core
//
//  Created by Jake Heiser on 8/27/17.
//

import Foundation
import PathKit
import Regex
import SwiftCLI

public struct Package: Decodable {
    
    public struct Provider: Decodable {
        public let name: String
        public let values: [String]
    }
    
    public struct Product: Decodable {
        public let name: String
        public let product_type: String
        public var targets: [String]
        public let type: String? // If library, static, dynamic, or nil; if executable, nil
        
        public var isExecutable: Bool {
            return product_type == "executable"
        }
    }
    
    public struct Dependency: Decodable {
        public struct Requirement: Decodable {
            public enum RequirementType: String, Decodable {
                case range
                case branch
                case exact
                case revision
            }
            public let type: RequirementType
            public let lowerBound: String?
            public let upperBound: String?
            public let identifier: String?
            
            public init(type: RequirementType, lowerBound: String?, upperBound: String?, identifier: String?) {
                self.type = type
                self.lowerBound = lowerBound
                self.upperBound = upperBound
                self.identifier = identifier
            }
            
            public init(version: Version){
                self.init(type: .range, lowerBound: version.raw, upperBound: Version(version.major + 1, 0, 0).raw, identifier: nil)
            }
        }
        
        public let url: String
        public var requirement: Requirement
    }
    
    public struct Target: Decodable {
        public struct Dependency: Decodable {
            public let name: String
        }
        
        public let name: String
        public let isTest: Bool
        public var dependencies: [Dependency]
        public let path: String?
        public let exclude: [String]
        public let sources: [String]?
        public let publicHeadersPath: String?
    }
    
    public static let packagePath = Path("Package.swift")
    
    public let name: String
    public let pkgConfig: String?
    public let providers: [Provider]?
    public private(set) var products: [Product]
    public private(set) var dependencies: [Dependency]
    public private(set) var targets: [Target]
    public let swiftLanguageVersions: [Int]?
    public let cLanguageStandard: String?
    public let cxxLanguageStandard: String?
    
    public static func load(in directory: Path = ".") throws -> Package {
        let data = try SPM(directory: directory).dumpPackage()
        return try load(data: data)
    }
    
    public static func load(data: Data) throws -> Package {
        do {
            return try JSONDecoder().decode(Package.self, from: data)
        } catch {
            throw IceError(message: "couldn't parse Package.swift")
        }
    }
    
    private static let libRegex = Regex("\\.library\\( *name: *\"([^\"]*)\"")
    public static func retrieveLibrariesOfDependency(named dependency: String) -> [String] {
        let path = Path(".build/checkouts").glob("\(dependency)*")[0]
        guard let contents: String = try? (path + packagePath).read().replacingOccurrences(of: "\n", with: " ") else {
            return []
        }
        let matches = libRegex.allMatches(in: contents)
        #if swift(>=4.1)
        return matches.compactMap { $0.captures[0] }
        #else
        return matches.flatMap { $0.captures[0] }
        #endif
    }
    
    // MARK: - Products
    
    public enum ProductType {
        case executable
        case library
        case staticLibrary
        case dynamicLibrary
    }
    
    public mutating func addProduct(name: String, type: ProductType, targets: [String]) {
        let productType: String
        switch type {
        case .executable: productType = "executable"
        case .library, .staticLibrary, .dynamicLibrary: productType = "library"
        }
        let libraryType: String?
        switch type {
        case .staticLibrary: libraryType = "static"
        case .dynamicLibrary: libraryType = "dynamic"
        case .library, .executable: libraryType = nil
        }
        let newProduct = Product(name: name, product_type: productType, targets: targets, type: libraryType)
        products.append(newProduct)
    }
    
    public mutating func removeProduct(name: String) throws {
        guard let index = products.index(where: { $0.name == name }) else {
            throw IceError(message: "can't remove product \(name)")
        }
        products.remove(at: index)
    }
    
    // MARK: - Dependencies
    
    public mutating func addDependency(ref: RepositoryReference, requirement: Dependency.Requirement) {
        dependencies.append(Dependency(
            url: ref.url,
            requirement: requirement
        ))
    }
    
    public mutating func updateDependency(dependency: Dependency, to requirement: Dependency.Requirement) throws {
        guard let index = dependencies.index(where: { $0.url == dependency.url }) else {
            throw IceError(message: "can't update dependency \(dependency.url)")
        }
        dependencies[index].requirement = requirement
    }
    
    public mutating func removeDependency(named name: String) throws {
        guard let index = dependencies.index(where: { RepositoryReference(url: $0.url).name == name }) else {
            throw IceError(message: "can't remove dependency \(name)")
        }
        dependencies.remove(at: index)
        
        var libs = Package.retrieveLibrariesOfDependency(named: name)
        if libs.isEmpty {
            libs.append(name)
        }
        for lib in libs {
            removeDependencyFromTargets(named: lib)
        }
    }
    
    private func requirement(for version: Version) -> Dependency.Requirement {
        return Dependency.Requirement(
            type: .range,
            lowerBound: version.raw,
            upperBound: Version(version.major + 1, 0, 0).raw,
            identifier: nil
        )
    }
    
    // MARK: - Targets
    
    public mutating func addTarget(name: String, isTest: Bool, dependencies: [String]) {
        let dependencies = dependencies.map { Package.Target.Dependency(name: $0) }
        let newTarget = Target(
            name: name,
            isTest: isTest,
            dependencies: dependencies,
            path: nil,
            exclude: [],
            sources: nil,
            publicHeadersPath: nil
        )
        targets.append(newTarget)
    }
    
    public mutating func depend(target: String, on lib: String) throws {
        guard let targetIndex = targets.index(where:  { $0.name == target }) else {
            throw IceError(message: "target '\(target)' not found")
        }
        if targets[targetIndex].dependencies.contains(where: { $0.name == lib }) {
            return
        }
        targets[targetIndex].dependencies.append(Target.Dependency(name: lib))
    }
    
    public mutating func removeTarget(named name: String) throws {
        guard let index = targets.index(where: { $0.name == name }) else {
            throw IceError(message: "can't remove target \(name)")
        }
        targets.remove(at: index)
        
        removeDependencyFromTargets(named : name)
        
        products = products.map { (oldProduct) in
            var newProduct = oldProduct
            newProduct.targets = newProduct.targets.filter { $0 != name }
            return newProduct
        }
    }
    
    // MARK: - Helpers
    
    private mutating func removeDependencyFromTargets(named name: String) {
        targets = targets.map { (oldTarget) in
            var newTarget = oldTarget
            newTarget.dependencies = newTarget.dependencies.filter { $0.name != name }
            return newTarget
        }
    }
    
    // MARK: -
    
    public func write(to stream: WritableStream? = nil, directory: Path = Path.current) throws {
        let writeStream: WritableStream
        if let stream = stream {
            writeStream = stream
        } else {
            let path = directory + Package.packagePath
            try path.write(Data())
            guard let fileStream = WriteStream(path: path.string) else  {
                throw IceError(message: "couldn't write to \(path)")
            }
            writeStream = fileStream
        }
        
        let writePackage = Ice.config.get(\.reformat, directory: directory) ? formatted() : self
        let writer = PackageWriter(stream: writeStream)
        writer.write(package: writePackage)
    }
    
}

// MARK: - Formatted

extension Package {
    
    public func formatted() -> Package {
        return Package(
            name: name,
            pkgConfig: pkgConfig,
            providers: providers?.map(Provider.formatted),
            products: products.map(Product.formatted).sorted(by: Product.packageSort),
            dependencies: dependencies.sorted(by: Dependency.packageSort),
            targets: targets.map(Target.formatted).sorted(by: Target.packageSort),
            swiftLanguageVersions: swiftLanguageVersions?.sorted(),
            cLanguageStandard: cLanguageStandard,
            cxxLanguageStandard: cxxLanguageStandard
        )
    }
    
}

extension Package.Provider {
    
    static func formatted(product: Package.Provider) -> Package.Provider {
        return Package.Provider(
            name: product.name,
            values: product.values.sorted()
        )
    }
    
}

extension Package.Product {
    
    static func formatted(product: Package.Product) -> Package.Product {
        return Package.Product(
            name: product.name,
            product_type: product.product_type,
            targets: product.targets.sorted(),
            type: product.type
        )
    
    }
    
    static func packageSort(lhs: Package.Product, rhs: Package.Product) -> Bool {
        if lhs.isExecutable && !rhs.isExecutable { return true }
        if !lhs.isExecutable && rhs.isExecutable { return false }
        return lhs.name < rhs.name
    }
    
}

extension Package.Dependency {
    
    static func packageSort(lhs: Package.Dependency, rhs: Package.Dependency) -> Bool {
        return RepositoryReference(url: lhs.url).name < RepositoryReference(url: rhs.url).name
    }
    
}

extension Package.Target {
    
    static func formatted(target: Package.Target) -> Package.Target {
        return Package.Target(
            name: target.name,
            isTest: target.isTest,
            dependencies: target.dependencies.sorted { $0.name < $1.name },
            path: target.path,
            exclude: target.exclude.sorted(),
            sources: target.sources?.sorted(),
            publicHeadersPath: target.publicHeadersPath
        )
    }
    
    static func packageSort(lhs: Package.Target, rhs: Package.Target) -> Bool {
        if lhs.isTest && !rhs.isTest { return false }
        if !lhs.isTest && rhs.isTest { return true }
        return lhs.name < rhs.name
    }
    
}
