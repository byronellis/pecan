import TUISuite

public struct Configurator : Component {
    public var body : some Component {
        VStack {
            HStack {
                Spacer()
                Text("Configuration")
                Spacer()
            }.background().frame(height:.fixed(1)).reverse()
            HStack {
                VStack {
                    Text("[P]roviders")
                    Text("[A]gents")
                    Text("[R]outes")
                    Spacer()
                    HStack(spacing:1) {
                        Spacer()
                        Text("Save")
                        Text("Cancel")
                    }.frame(height:.fixed(1))
                }
                .frame(width: .fixed(25))
                .border(color: .border)
                VStack {
                    Spacer()
                }.border(color: .border)
            }
            HStack(spacing:1) {
                Text("Use [↑/↓ Arrows] to navigate items in the sidebar.")
                Spacer()
            }.background().frame(height:.fixed(1)).reverse()
        }
    }
    
    public static func run() {
        var app = Application {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    VStack {
                        Configurator()
                    }
                    .frame(width:.fixed(80),height:.fixed(24))
                    Spacer()
                }
                Spacer()
            }

        }
        app.run()
    }
}


