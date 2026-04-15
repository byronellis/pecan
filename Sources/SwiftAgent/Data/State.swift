//
//  State.swift
//  pecan
//
//  Created by Byron Ellis on 4/13/26.
//

@MainActor
@propertyWrapper
public struct State<Value> : DynamicProperty {
    private let initialValue: Value
    
    var anyInitialValue:Any { initialValue}
    var getter:(() -> Any)?
    var setter:((Any,Transaction) -> ())?
    
    public init(wrappedValue value: Value) {
        initialValue = value
    }
    
    public var wrappedValue: Value {
        get { getter?() as? Value ?? initialValue }
        nonmutating set { setter?(newValue, Transaction._active ?? .init())}
    }
    
    public var projectedValue: Binding<Value> {
        guard let getter = getter, let setter = setter else {
            fatalError("\(#function) not available outside of `body`")
        }
        return .init(get: { getter() as! Value },set: { newValue, transaction in setter(newValue, Transaction._active ?? transaction) })
    }
}

public extension State where Value: ExpressibleByNilLiteral {
    init() { self.init(wrappedValue: nil) }
}
