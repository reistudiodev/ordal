import DBClientCore

// Placeholder until the WinUI layer is added (planned: swift-winrt + WinUI 3).
// For now this proves the Rust core links and runs on Windows.
print(greet(name: "Windows"))
print("Core v\(coreVersion())")
