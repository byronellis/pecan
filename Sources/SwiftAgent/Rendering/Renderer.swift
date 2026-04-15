//
//  Renderer.swift
//  pecan
//
//  Created by Byron Ellis on 4/14/26.
//

public protocol Renderer : AnyObject {
    typealias Mounted = MountedElement<Self>
    typealias MountedHost = MountedHostPrompt<Self>
    associatedtype TargetType: Target
    
    func mountTarget(before sibling: TargetType?,to parent: TargetType,with host: MountedHost) -> TargetType?
    
    
    
    func primitiveBody(for prompt: Any) -> AnyPrompt?
    
    func isPrimitivePrompt(_ type: Any.Type) -> Bool
}

public final class Reconciler<R:Renderer> {
    public let rootTarget: R.TargetType
    private let rootElement: MountedElement<R>
    private(set) unowned var renderer: R
    
    public init<P:Prompt>(prompt: P,target:R.TargetType,renderer:R) {
        self.renderer = renderer
        rootTarget = target
        rootElement = AnyPrompt(prompt).makeMountedPrompt(renderer, target, nil)
        performInitialMount()
    }
    
    
    func performInitialMount() {
        rootElement.mount(in: self)
    }
    
    func render(compositePrompt: MountedCompositePrompt<R>) -> AnyPrompt {
        let prompt = body(of: compositePrompt, keyPath: \.prompt.prompt)
        guard let renderedBody = renderer.primitiveBody(for: prompt) else {
            return compositePrompt.prompt.bodyClosure(prompt)
        }
        return renderedBody
    }
    

    
    private func body(of compositeElement: MountedCompositeElement<R>,keyPath: ReferenceWritableKeyPath<MountedCompositeElement<R>,Any>) -> Any {
        compositeElement[keyPath: keyPath]
    }
}
