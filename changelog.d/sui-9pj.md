### Added

- A `:path_types` entry may be `{:shape, members}`, the inline arm
  `statifier_datamodel` 0.4.0 added to a type expression. The expression
  editor offers each member as a path of its own, after the path declaring it
  and through nesting, and types a read of one by that member - `card.brand`
  takes the `brand` member's type where `card` is declared a shape, with an
  exact entry for the longer path still winning. The path holding the shape
  declares nothing itself: a structure is not a kind the grammar compares, so
  its row offers what an undeclared path offers and raises no advisory, while
  `data-declared-kind` says `shape`. An inline shape has no document spelling,
  so it reaches the component only through the `:path_types` map a consumer
  builds; a `:document` alone still renders exactly as it did.

### Changed

- The `statifier_datamodel` floor is `~> 0.4`, for the inline shape arm of its
  type expression. A host handing over a `:document` gets more of it typed as
  a result, without changing anything here: an entry whose `type` names a
  declaration the document's `types` key declares is flattened into that
  declaration's fields by sd's own index, so `card.brand` is completed and
  typed where the document declares `card` a named shape and spells no field
  of its own. That is sd's projection answering more fully, and every path it
  already answered for answers the same.
