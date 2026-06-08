# Semantic Element Registration

## Purpose

The semantic registration system enables Playwright-like automated testing and AI-driven control of Scenic applications. Elements are found and clicked by ID rather than hardcoded screen coordinates, making tests deterministic and layout-independent.

## Architecture Overview

A parallel semantic compilation pipeline operates alongside Scenic's existing script compilation. When a scene pushes a graph, both pipelines run concurrently — the script pipeline feeds the rendering driver, while the semantic pipeline populates ETS tables that testing and MCP automation tools can query.

```
Scene Graph (Primitives + Components)
        │
        ├──► GraphCompiler (existing) ──► Script Table (ETS) ──► Driver (rendering)
        │
        └──► SemanticCompiler (parallel) ──► Semantic Tables (ETS) ──► MCP / Testing
```

### Key design decisions

1. **Parallel pipeline** — semantic compilation never blocks or interferes with rendering
2. **Opt-in via element IDs** — any primitive with an `:id` opt is registered automatically; primitives without IDs are ignored
3. **ETS-backed storage** — two tables per viewport: `semantic_table` (ordered_set, hierarchical) and `semantic_index` (set, flat lookup)
4. **Feature-flagged** — `semantic_registration: false` in viewport config disables the entire system with zero overhead
5. **Fire-and-forget compilation** — uses `Task.start`, never sends replies to the calling process

## Data Model

Each registered element is stored as a `Scenic.Semantic.Compiler.Entry`:

| Field | Type | Description |
|-------|------|-------------|
| `id` | `atom` | Element identifier (from `:id` opt or explicit semantic metadata) |
| `type` | `atom` | Primitive type (`:rect`, `:circle`, `:text`, `:component`, etc.) |
| `module` | `module` | The primitive or component module |
| `parent_id` | `atom \| nil` | Parent element in the semantic tree |
| `children` | `[atom]` | Child element IDs |
| `local_bounds` | `bounds` | Bounding box in local coordinate space |
| `screen_bounds` | `bounds` | Bounding box in screen coordinates (Phase 1: equals `local_bounds`) |
| `clickable` | `boolean` | Whether the element accepts click input |
| `focusable` | `boolean` | Whether the element can receive focus |
| `label` | `String.t \| nil` | Human-readable label |
| `role` | `atom \| nil` | Semantic role (`:button`, `:menu_item`, etc.) |
| `hidden` | `boolean` | Visibility flag |
| `z_index` | `integer` | Depth ordering from tree position |

Bounds are `%{left, top, width, height}` maps.

## ETS Table Layout

**`semantic_table`** (ordered_set) — keyed by `{scene_name, element_id}`:

```
{{:_root_, :save_button}, %Entry{...}}
{{:_root_, :cancel_button}, %Entry{...}}
{{:menu_bar, :menu_file}, %Entry{...}}
```

**`semantic_index`** (set) — keyed by `element_id` for flat lookup:

```
{:save_button, {:_root_, :save_button}}
{:menu_file, {:menu_bar, :menu_file}}
```

## ViewPort Integration

Three fields added to `Scenic.ViewPort` struct:

- `semantic_table` — ETS table ref (or `nil` when disabled)
- `semantic_index` — ETS table ref (or `nil` when disabled)
- `semantic_enabled` — boolean

On `put_graph/4`, if semantic is enabled, a fire-and-forget task compiles the graph into entries and inserts them into both tables.

## Query API

`Scenic.ViewPort.Semantic` provides the public interface:

| Function | Description |
|----------|-------------|
| `find_element(viewport, id)` | Lookup by ID |
| `find_clickable_elements(viewport, filter)` | All clickable elements, optionally filtered |
| `element_at_point(viewport, x, y)` | Hit-test at screen coordinates |
| `click_element(viewport, id)` | Calculate center and send mouse events through driver |
| `get_semantic_tree(viewport, root_id)` | Hierarchical tree from a root |

`click_element/2` sends real `{:cursor_button, ...}` input events through the viewport, simulating an actual user click at the element's center point.

## Component Registration

Components register their own semantic elements by writing directly to the viewport's ETS tables. The pattern used by MenuBar, SideNav, and the Widget Workbench:

```elixir
if viewport.semantic_table && viewport.semantic_enabled do
  entry = %{id: semantic_id, type: :button, clickable: true, ...}
  :ets.insert(viewport.semantic_table, {{scene_name, semantic_id}, entry})
  :ets.insert(viewport.semantic_index, {semantic_id, {scene_name, semantic_id}})
end
```

Components guard on `semantic_table` and `semantic_enabled` so they degrade gracefully when semantic registration is off.

## MCP Integration

`scenic_mcp` wraps the query API as MCP tools, allowing AI assistants (via Claude Desktop, etc.) to:

- `find_clickable_elements()` — discover interactive elements
- `click_element(element_id: "save_button")` — click by ID
- `inspect_viewport()` — read the semantic DOM

## Implementation Status

### Phase 1 — Foundation (complete)

- ViewPort struct fields and ETS table initialization
- `Scenic.Semantic.Compiler` with recursive graph walking
- `Scenic.ViewPort.Semantic` query API
- Parallel compilation via `Task.start`
- Direct ETS registration in MenuBar, SideNav, Widget Workbench
- Test suite (10 tests)

### Phase 2 — Transform-aware coordinates (not started)

- Accumulate transform matrices during compilation
- Apply translate/rotate/scale to compute `screen_bounds`
- Handle nested group transforms

### Phase 3 — Component sub-scenes (not started)

- Register elements inside component sub-graphs
- Aggregate component boundaries from children
- Full parent-child linking across scene boundaries

### Phase 4 — Advanced queries (not started)

- Query by type, text content, role
- Visibility and z-order calculations
- Font metrics for accurate text bounds
- Spatial indexing for coordinate queries

## Performance

- ~140 bytes per registered element
- 1000 elements ≈ 140KB overhead
- O(1) ID lookup, O(n) filtered queries
- Zero overhead when `semantic_enabled: false` (no ETS tables created)
- No blocking of the rendering pipeline

## Alternatives Considered

| Approach | Why not |
|----------|---------|
| Script table analysis | Reverse-engineering binary scripts loses semantic metadata |
| Graph decoration | Requires manual annotation, pushes transform math to developers |
| Runtime introspection | Race conditions, performance impact on scene processes |
