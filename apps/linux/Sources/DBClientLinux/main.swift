import DBClientCore

// Placeholder until the GTK layer is added (planned: GTK 4 / libadwaita Swift bindings).
// For now this proves the Rust core links and runs on Linux.
print(greet(name: "Linux"))
print("Core v\(coreVersion())")
