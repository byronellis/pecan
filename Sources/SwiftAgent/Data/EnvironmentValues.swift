//
//  EnvironmentValues.swift
//  pecan
//
//  Created by Byron Ellis on 4/13/26.
//

import Foundation

@MainActor
public struct EnvironmentValues {
    public static let shared = EnvironmentValues()
    
    private var values: [ObjectIdentifier:Any] = [:]
    public init() { }
    public subscript<K>(key:K.Type) -> K.Value where K: EnvironmentKey {
        get {
            if let val = values[ObjectIdentifier(key)] as? K.Value {
                return val
            }
            return key.defaultValue
        }
        set {
            values[ObjectIdentifier(key)] = newValue
        }
    }
    subscript<B>(bindable:ObjectIdentifier) -> B? where B:ObservableObject{
        get {
            values[bindable] as? B
        }
        set {
            values[bindable] = newValue
        }
    }
}



public protocol EnvironmentKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

struct IsEnabledKey : EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var isEnabled: Bool {
        get {
            self[IsEnabledKey.self]
        }
        set {
            self[IsEnabledKey.self] = newValue
        }
    }
}
