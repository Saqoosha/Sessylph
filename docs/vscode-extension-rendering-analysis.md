# Claude Code VS Code Extension — Rendering Architecture Analysis

> Analyzed from `/Users/hiko/.vscode/extensions/anthropic.claude-code-2.0.75-darwin-arm64/`
> Version: 2.0.75 (darwin-arm64), analyzed 2026-03-26

## Overview

The Claude Code VS Code extension renders its UI as a **React webview** (not using VS Code's integrated terminal). The webview code is bundled into:
- `webview/index.js` — 4.3MB minified React app
- `webview/index.css` — 189KB minified CSS
- `webview/codicon-37A3DWZT.ttf` — VS Code icon font

The extension host (`extension.js`, 256 lines minified) manages the lifecycle and communicates with the webview via VS Code's `postMessage` API.

## Markdown Rendering

**Library:** `react-markdown` (from remarkjs)

Configuration:
```javascript
remarkPlugins: [NX]       // Custom remark plugin (minified name)
rehypePlugins: []          // Default empty
remarkRehypeOptions: { allowDangerousHtml: true }
```

Links render with `target="_blank"` for external opening:
```jsx
components: {
  a: ({ href, children }) => <a href={href} target="_blank" rel="...">...</a>
}
```

**Sessylph implication:** Swift equivalent would be `AttributedString(markdown:)` for basic formatting, or `swift-markdown` + custom `MarkupVisitor` for full control. Code blocks need separate handling.

## Stream Event Assembly

A `StreamAssembler` class (`Wee` in minified code) processes raw Claude API streaming events:

```
message_start        → Create new message object
content_block_start  → Add new content block (text, thinking, tool_use, etc.)
content_block_delta  → Append to current block (text_delta, thinking_delta, input_json_delta)
content_block_stop   → Finalize block
message_delta        → Update message-level fields (usage, stop_reason)
message_stop         → Finalize message
```

**Key pattern:** `parent_tool_use_id` enables nested rendering — sub-agent tool calls are grouped under their parent tool card.

**Assembler per parent:** A Map of assemblers keyed by `parent_tool_use_id` (or `"root"`) handles parallel sub-agents:
```javascript
processStreamEvent(event, parent_tool_use_id) {
    let assembler = this.assemblers.get(parent_tool_use_id ?? "root");
    // ...
}
```

## Tool Rendering — Class Hierarchy

All tool renderers follow a common base class pattern with `header()`, `body()`, and `permissionRequest()` methods:

### Base Class: `_n` (generic tool)
```javascript
header(input, output)          // Tool name + one-line summary
body(input, output)            // IN/OUT grid layout
permissionRequest(...)         // Permission UI for this tool
renderInput(input, output)     // "IN" row
renderOutput(input, result)    // "OUT" row
```

### File Operations Base: `Yv` (extends `_n`)
Adds file path display helpers (`fileTool` header pattern).

### All Tool Renderers

| Class | Base | Tool Name | Key Rendering |
|-------|------|-----------|---------------|
| `s6` | `_n` | `Bash` | command + description in header, output in body |
| (anon) | `_n` | `Glob` | file pattern matches |
| (anon) | `_n` | `Grep` | search results |
| (anon) | `_n` | `Search` | code search |
| (anon) | `_n` | `WebFetch` | URL fetch results |
| (anon) | `_n` | `WebSearch` | web search results |
| (anon) | `_n` | `TodoWrite` | task list rendering |
| (anon) | `_n` | `Task` / `TaskOutput` | sub-task card |
| (anon) | `_n` | `AgentOutputTool` | agent output |
| (anon) | `_n` | `SlashCommand` | slash command execution |
| `h6` | `Yv` | `Read` | file path in header, content preview |
| (anon) | `Yv` | `ReadCoalesced` | multiple reads merged into one card |
| `W2` | `Yv` | `Edit` / `Write` | file path + diff |
| `kk` | `Yv` | `AskUserQuestion` | interactive question to user |

### Read Coalescing

When multiple consecutive `Read` tool calls occur, the extension coalesces them into a single `ReadCoalesced` card:
```javascript
{
    type: "tool_use",
    id: "coalesced_" + Math.random().toString(36).slice(2),
    name: "ReadCoalesced",
    input: { fileReads: [...] }
}
```

This reduces visual clutter when Claude reads many files in sequence.

## Tool Card Layout (CSS Modules)

The tool card uses a CSS modules pattern with minified class names:

```javascript
xt = {
    root:                           "xr",    // Card container
    toolSummary:                    "fr",    // Collapsed summary line
    toolNameText:                   "vr",    // Tool name (bold)
    toolNameTextSecondary:          "O",     // Secondary text after name
    toolNameTextSecondaryPlaintext: "wr",    // Plain text variant
    toolBody:                       "kr",    // Expanded body container
    toolBodyPlainText:              "mo",    // Plain text body
    toolBodyGrid:                   "yr",    // Grid layout (IN/OUT rows)
    toolBodyRow:                    "bo",    // Single row
    toolBodyRowLabel:               "zr",    // "IN" / "OUT" label
    toolBodyRowContent:             "b",     // Content area
    toolBodyRowContent_disableClipping: "Br" // No overflow clipping
}
```

### Card Structure
```
┌─────────────────────────────────────────┐
│ [icon] ToolName  secondary text    [▼]  │  ← header (always visible)
├─────────────────────────────────────────┤
│ IN  │ command / file path / input       │  ← toolBodyRow
│─────┼───────────────────────────────────│
│ OUT │ output / result                   │  ← toolBodyRow
└─────────────────────────────────────────┘
```

The IN/OUT rows are clickable (cursor: pointer) to expand/copy content.

## Permission System

### Model
```javascript
class PermissionRequest {
    constructor(channelId, toolName, inputs, suggestions) { ... }
    onResolved(callback)  // Register resolution handler
}
```

### Flow
1. CLI sends `tool_permission_request` via WebSocket/IPC
2. Extension creates `PermissionRequest` instance
3. Adds to reactive `permissionRequests` signal array (`Ti([])`)
4. Webview renders permission banner
5. User clicks Allow/Deny
6. `onResolved` callback fires with result
7. Extension sends `tool_permission_response` back to CLI
8. Request removed from `permissionRequests` array

### Tab Badge
Permission requests show as a badge on the tab:
```javascript
let hasPermission = (session?.permissionRequests.value.length ?? 0) > 0;
tab.renameTab(title, hasPermission, hasUnseenCompletion);
```

## Message Structure (Display Model)

Messages use a `parent_tool_use_id` based tree for nesting:

```
assistant message (root)
  ├── text block
  ├── thinking block
  ├── tool_use (Bash)
  │   └── tool_result
  ├── tool_use (Agent)
  │   ├── assistant message (sub-agent, parent_tool_use_id = Agent's id)
  │   │   ├── text block
  │   │   ├── tool_use (Read)
  │   │   └── tool_use (Edit)
  │   └── tool_result (agent output)
  └── text block (after tools)
```

### Content Block Types

From the code's switch statements:
- `text` — Markdown text
- `thinking` — Extended thinking (collapsible)
- `tool_use` — Tool invocation card
- `tool_result` — Tool execution result
- `server_tool_use` — Server-side tool
- `web_search_tool_result` — Web search
- `image` — Image content
- `document` — Document reference
- `redacted_thinking` — Redacted thinking block
- `citation` — Citation reference

## Reactive State Management

The extension uses a custom reactive signal system (similar to Solid.js signals):
- `Ti(initialValue)` — Create reactive signal
- `jr(() => derived)` — Computed/derived signal
- `.value` — Read/write signal value

Key state signals:
```javascript
permissionRequests = Ti([])       // Pending permissions
authStatus = Ti(undefined)        // Auth state
config = Ti()                     // Extension config
messages                          // Message feed (signal)
worktreeSupported = Ti(false)     // Git worktree support
hasUnseenCompletion = Ti(false)   // Unread completion badge
```

## Extension Host ↔ Webview Communication

Messages via VS Code `postMessage` API:

### Host → Webview
- Session state changes
- Stream events from CLI
- Permission requests
- Auth status updates
- Config changes

### Webview → Host
- User messages (prompt input)
- Permission responses (allow/deny)
- UI actions (interrupt, set model, set permission mode)

## Key Takeaways for Sessylph v2

1. **Tool rendering pattern**: Base class with `header()` + `body()` is clean and extensible. Sessylph should use a similar protocol-oriented approach in Swift.

2. **Read coalescing**: Worth implementing — multiple sequential reads should be grouped.

3. **Stream assembler**: Essential component — accumulates deltas into complete content blocks, handles parent_tool_use_id nesting.

4. **IN/OUT grid**: Simple but effective tool card layout. Each tool card shows input and output in labeled rows.

5. **Permission as banner**: Permissions are shown inline in the message feed, not as modal dialogs. This is less disruptive.

6. **react-markdown**: Standard choice. Sessylph can use `AttributedString(markdown:)` for inline formatting and custom views for code blocks.

7. **Tab badge for permissions**: Good UX — user sees at a glance which tab needs attention.

8. **Nested sub-agents**: `parent_tool_use_id` tree structure is essential for Agent tool rendering.
