//
//  MountedHostPrompt.swift
//  pecan
//
//  Created by Byron Ellis on 4/14/26.
//

public final class MountedHostPrompt<R:Renderer> : MountedElement<R> {
    private let parentTarget: R.TargetType
    private(set) var target: R.TargetType?
    
    init(_ prompt: AnyPrompt,_ parentTarget : R.TargetType,_ parent: MountedElement<R>?) {
        self.parentTarget = parentTarget
        super.init(prompt, parent)
    }
    
    override func mount(before sibling: R.TargetType? = nil, on parent: MountedElement<R>? = nil, in reconciler: Reconciler<R>) {
        super.prepareForMount()
        
        guard let target = reconciler.renderer.mountTarget(before: sibling, to: parentTarget, with: self) else {
            return
        }
        self.target = target
        guard !prompt.children.isEmpty else {
            return
        }
        
        let isGroupPrompt = prompt.type is GroupPrompt.Type
        mountedChildren = prompt.children.map {
            $0.makeMountedPrompt(reconciler.renderer, target, self)
        }
        
        mountedChildren.forEach {
            $0.mount(before: isGroupPrompt ? sibling : nil, on: self, in: reconciler)
        }
        
        super.mount(before: sibling, on: parent, in: reconciler)
    }
}
