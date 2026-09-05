### Removed

- `StatifierUI.Live.ExpressionInput.display_label/1`. It lowercased a
  word-shaped lexeme so a dropdown could read `in` where the decompiler wrote
  `IN`. Since operator labels became the grammar's own display phrases,
  delivered by `StatifierUI.Expression.operators/1`, every label it could be
  handed was already display-cased and it returned its argument unchanged.
  Operator options now carry the grammar's phrase verbatim, which leaves one
  spelling of a display phrase in the system and it is the vocabulary's.
