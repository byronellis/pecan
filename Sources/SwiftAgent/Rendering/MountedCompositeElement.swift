//
//  MountedCompositeElement.swift
//  pecan
//
//  Created by Byron Ellis on 4/14/26.
//

public class MountedCompositeElement<R:Renderer> : MountedElement<R> {
    let parentTarget: R.TargetType
    var storage = [Any]()
    init(_ prompt: AnyPrompt,_ parentTarget:R.TargetType,_ parent:MountedElement<R>?) {
        self.parentTarget = parentTarget
        super.init(prompt,parent)
    }
}
