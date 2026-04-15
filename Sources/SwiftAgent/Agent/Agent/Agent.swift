//
//  Agent.swift
//  pecan
//
//  Created by Byron Ellis on 4/12/26.
//

public protocol Agent {
    associatedtype Body: Soul
    
    
    var body : Body { get }
    init()
}

