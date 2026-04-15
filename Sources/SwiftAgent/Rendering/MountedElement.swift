//
//  MountedElement.swift
//  pecan
//
//  Created by Byron Ellis on 4/14/26.
//

public class MountedElement<R:Renderer> {
    enum Storage {
        case agent(_AnyAgent)
        case soul(_AnySoul)
        case prompt(AnyPrompt)
        
        var type: Any.Type {
            switch self {
                
            case .agent(let agent):
                return agent.type
            case .soul(let soul):
                return soul.type
            case .prompt(let prompt):
                return prompt.type
            }
        }
    }
    
    private var storage: Storage
    var type : Any.Type { storage.type }
    
    public internal(set) var prompt: AnyPrompt {
        get {
            if case let .prompt(anyPrompt) = storage {
                return anyPrompt
            } else {
                fatalError("The MountedElement is of type \(type) not `Prompt`")
            }
        }
        set {
            storage = .prompt(newValue)
        }
    }
    
    var mountedChildren = [MountedElement<R>]()
    private(set) weak var parent: MountedElement<R>?
    
    init(_ prompt: AnyPrompt,_ parent: MountedElement<R>?) {
        storage = .prompt(prompt)
        self.parent = parent
    }

    func prepareForMount() {        
    }
    func mount(before sibling: R.TargetType? = nil,on parent: MountedElement<R>? = nil,in reconciler: Reconciler<R>) {
    }
}

extension AnyPrompt {
    func makeMountedPrompt<R:Renderer>(_ renderer: R,_ parentTarget: R.TargetType,_ parent: MountedElement<R>?) -> MountedElement<R> {
        if(type == EmptyPrompt.self) {
            return MountedEmptyPrompt(self,parent)
        } else if bodyType == Never.self && !renderer.isPrimitivePrompt(type) {
            return MountedHostPrompt(self, parentTarget, parent)
        } else {
            return MountedCompositePrompt(self, parentTarget, parent)
        }
    }
}
