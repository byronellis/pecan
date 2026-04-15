//
//  Transaction.swift
//  pecan
//
//  Created by Byron Ellis on 4/13/26.
//

public struct Transaction {
    @MainActor static var _active: Self? 
}
