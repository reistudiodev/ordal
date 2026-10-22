import DBClientCore

// Placeholder until the GTK layer is added (planned: GTK 4 / libadwaita Swift bindings).
// For now this proves the Rust core links and runs on Linux.
print("DB Client core v\(coreVersion()) is linked on Linux.")
print(classifyStatement(sql: "DROP TABLE t") == .destructive ? "Safety checks: ok" : "Safety checks: broken")
