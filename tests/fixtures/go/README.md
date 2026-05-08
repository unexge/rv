# Go fixtures

The cross-language scenario matrix defines 10 scenarios (see the epic task
description). Two of them do not apply to Go:

## Skipped: `add_decl_to_container`

Go has no nested top-level containers in v1. `struct_type` and
`interface_type` are not modelled as containers because their fields /
method-specs are not Decls - they are tokens inside a leaf Decl body (see
Q4 of the epic).

Methods are top-level Decls (`method_declaration`), not nested inside the
type they belong to. "Add a method to a type" is therefore identical to
the `add_function` scenario with a `method_declaration` instead of a
`function_declaration`, and adds no new coverage. Omitted for Go.

## Skipped: `nested_body_change`

Same reason. No containers means no nesting. "Edit a method body" reduces
to `body_change` on a `method_declaration`, already covered by the
`body_change` fixture shape. Omitted for Go.

## Real fixtures (8)

- `whitespace_only`
- `rename_function`
- `add_function`
- `remove_function`
- `reorder_decls`
- `body_change`
- `comment_only_change`
- `parse_error`
