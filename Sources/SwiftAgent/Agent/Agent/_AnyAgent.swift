//
//  _AnyAgent.swift
//  pecan
//
//  Created by Byron Ellis on 4/13/26.
//

public struct _AnyAgent : Agent {
    
    var agent: Any
    let type: Any.Type
    let bodyClosure: (Any) -> _AnySoul
    let bodyType: Any.Type
    
    public init<A:Agent>(_ agent: A) {
        self.agent = agent
        self.type  = A.self
        self.bodyClosure = { _AnySoul(($0 as! A).body) }
        self.bodyType = A.Body.self
    }
    
    public init() {
        fatalError("`AnyAgent` can not be initialized without an underlying Agent type.")
    }
    
    public var body: Never {
        fatalError("_AnyAgent should never call `body`.")
    }
    
}
