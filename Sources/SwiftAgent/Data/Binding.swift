//
//  Binding.swift
//  pecan
//
//  Created by Byron Ellis on 4/13/26.
//

@propertyWrapper
@dynamicMemberLookup
public struct Binding<Value> : DynamicProperty {
    public var wrappedValue : Value {
        get { get() }
        nonmutating set { set(newValue, transaction) }
    }
    public var transaction: Transaction
    private let get: () -> Value
    private let set: (Value, Transaction) -> ()
    
    public var projectedValue : Binding<Value> { self }
    public init(get: @escaping () -> Value,set: @escaping (Value) -> ()) {
        self.get = get
        self.set = { v,_ in set(v) }
        self.transaction = .init()
    }
    
    public init(get: @escaping () -> Value, set: @escaping (Value, Transaction) -> ()) {
        self.transaction = .init()
        self.get = get
        self.set = {
            set($0,$1)
        }
    }
    
    public subscript<Subject>(dynamicMember keyPath: WritableKeyPath<Value, Subject>) -> Binding<Subject> {
        .init(get: {
            self.wrappedValue[keyPath: keyPath]
        }, set: {
            self.wrappedValue[keyPath: keyPath] = $0
        })
    }
    
    public static func constant(_ value: Value) -> Self {
        .init(get: { value }, set: { _ in })
    }
}

public extension Binding {
    func transaction(_ transaction: Transaction) -> Binding<Value> {
        var binding = self
        binding.transaction = transaction
        return binding
    }
}

extension Binding : Identifiable where Value: Identifiable {
    public var id: Value.ID { wrappedValue.id }
}
