import OrdalCore

// Placeholder until the WinUI layer is added (planned: swift-winrt + WinUI 3).
// For now this proves the Rust core links and runs on Windows.
print("Ordal core v\(coreVersion()) is linked on Windows.")
print(classifyStatement(sql: "DROP TABLE t") == .destructive ? "Safety checks: ok" : "Safety checks: broken")
