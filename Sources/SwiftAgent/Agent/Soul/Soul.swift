//
//  Soul.swift
//  pecan
//
//  Created by Byron Ellis on 4/12/26.
//

public protocol Soul {
    associatedtype Body: Soul

    @SoulBuilder
    var body: Body { get }
}

extension Never : Soul {}

protocol PrimitiveSoul : Soul where Body == Never { }


extension PrimitiveSoul {
    public var body: Never {
        soulBodyError()
    }
}

extension Soul {
    func soulBodyError() -> Never {
        preconditionFailure("archetype() should not be called on \(Self.self).")
    }
}
