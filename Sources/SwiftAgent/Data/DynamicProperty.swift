//
//  DynamicProperty.swift
//  pecan
//
//  Created by Byron Ellis on 4/13/26.
//

public protocol DynamicProperty {
    mutating func update()
}

public extension DynamicProperty {
    mutating func update() {}
}
