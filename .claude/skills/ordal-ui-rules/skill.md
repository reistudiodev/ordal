---
name: "ordal-ui-rules"
description: "Use when designing or building any UI screen for the ordal database app on macOS, Windows or Linux."
---

# ordal UI/UX rules

Goal: DBeaver-level power with a fresh, calm, modern UI that feels native on each OS.

## Principles
- Native first: SwiftUI/AppKit on Mac, WinUI on Windows, GTK on Linux. Follow each platform's conventions for menus, shortcuts and window chrome.
- Calm by default: show the essentials and reveal advanced tools on demand (inspectors, command palette). No toolbars crowded with icons.
- Keyboard first: a command palette (Cmd/Ctrl+K) for every action, and shortcuts for run, new tab, switch connection and format.
- Fast and responsive: the UI never blocks on the database. Show progress, allow cancel, and use virtualized grids for large results.

## Layout
- Left sidebar: connections, then schemas/collections/keys, with search at the top.
- Center: tabbed editors (SQL, Mongo query, Redis command) with a results panel below.
- Right: an optional inspector for row, document or key details.
- Each connection gets a color tag, shown in the tab and window, so production is never mistaken for dev.

## Visual style
- Use system fonts and a monospace font for code and data. Use an 8pt spacing grid.
- Support light and dark mode from day one, with one accent color and few borders.
- Empty states explain the next step (for example, "Add your first connection").

## Safety UX
- Confirm destructive statements (DROP, DELETE without WHERE, FLUSHALL), with stronger warnings on production-tagged connections.
- Read-only mode per connection.

## Checks before shipping a screen
Run the design critique and accessibility review skills, and keep contrast at WCAG AA or better.