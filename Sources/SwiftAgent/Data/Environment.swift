//
//  Environment.swift
//  pecan
//
//  Created by Byron Ellis on 4/13/26.
//

@MainActor
protocol EnvironmentReader {
    mutating func setContent(from values: EnvironmentValues)
}

@propertyWrapper
@MainActor
public struct Environment<Value> : DynamicProperty {
    enum Content {
        case keyPath(KeyPath<EnvironmentValues,Value>)
        case value(Value)
    }
    
    private var content: Content
    private let keyPath: KeyPath<EnvironmentValues,Value>
    public init(_ keyPath: KeyPath<EnvironmentValues,Value>) {
        self.keyPath = keyPath
        self.content = .keyPath(keyPath)
    }
    
    mutating func setContent(from values: EnvironmentValues) {
        content = .value(values[keyPath: keyPath])
    }
    
    public var wrappedValue: Value {
        switch content {
        case .keyPath(let kp):
            return EnvironmentValues.shared[keyPath: kp]
        case .value(let v):
            return v
        }
    }
}

extension Environment : EnvironmentReader { }
