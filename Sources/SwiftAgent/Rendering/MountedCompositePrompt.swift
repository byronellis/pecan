//
//  MountedCompositePrompt.swift
//  pecan
//
//  Created by Byron Ellis on 4/14/26.
//

public final class MountedCompositePrompt<R:Renderer> : MountedCompositeElement<R> {
    override func mount(before sibling: R.TargetType? = nil, on parent: MountedElement<R>? = nil, in reconciler: Reconciler<R>) {
        super.prepareForMount()
        
        let childBody = reconciler.render(compositePrompt: self)
        let child: MountedElement<R> = childBody.makeMountedPrompt(reconciler.renderer, parentTarget, parent)
        
        mountedChildren = [child]
        child.mount(before: sibling, on: self, in: reconciler)
        
        super.mount(before: sibling, on: parent, in: reconciler)
    }
}
