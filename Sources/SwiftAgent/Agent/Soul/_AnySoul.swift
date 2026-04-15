//
//  _AnySoul.swift
//  pecan
//
//  Created by Byron Ellis on 4/13/26.
//
public struct _AnySoul : Soul {
    enum BodyResult {
        case soul(_AnySoul)
        case prompt(AnyPrompt)
    }
    
    var soul: Any
    let type: Any.Type
    let bodyClosure: (Any) -> BodyResult
    let bodyType: Any.Type
    
    init<S:Soul>(_ soul: S) {
        if let anySoul = soul as? _AnySoul {
            self = anySoul
        } else {
            self.soul = soul
            self.type = S.self
            self.bodyType = S.Body.self
            self.bodyClosure = { .soul(_AnySoul(($0 as! S).body)) }
        }
    }
    
    public var body : Never {
        soulBodyError()
    }
}
