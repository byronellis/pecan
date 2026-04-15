//
//  TupleSoul.swift
//  pecan
//
//  Created by Byron Ellis on 4/13/26.
//
extension Group: PrimitiveSoul, Soul where Content: Soul {
    
}

struct _TupleSoul<T> : PrimitiveSoul, Soul {
    var value : T
    public init(_ value: T) {
        self.value = value
    }
    var body : Never { soulBodyError() }
}
