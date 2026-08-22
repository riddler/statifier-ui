### Added

- Serializes statifier's `DatamodelChange` effect as the new
  `effect.datamodel_change` wire type, so consumers can observe datamodel
  values as they are written instead of only the variable names
  `session.datamodel` carries. The format version stays 1; new types are
  additive under the wire format's must-ignore rule.
