// The package entry point. ADR-0009: this package's JavaScript ships as source
// and the host's bundler compiles it, so a host adds
//
//     "statifier_ui": "file:../deps/statifier_ui/assets"
//
// to its own assets/package.json and imports from here:
//
//     import { StatifierUIHooks } from "statifier_ui"
//     let liveSocket = new LiveSocket("/live", Socket, {hooks: {...StatifierUIHooks}})
//
// Hook names are public API under ADR-0009, the same as an exported Elixir
// function: the Elixir side renders them as `phx-hook` and a rename is a
// breaking change for every host that registered the old one.

export { StatifierUIExpressionInput } from "./expression_input.js";
export { StatifierUIExpressionPicklist } from "./expression_picklist.js";

import { StatifierUIExpressionInput } from "./expression_input.js";
import { StatifierUIExpressionPicklist } from "./expression_picklist.js";

// Every hook this package ships, keyed by the name its component renders.
// Spreading this object is the one-line registration; a host that wants only
// some of them imports those by name instead.
export const StatifierUIHooks = {
  StatifierUIExpressionInput,
  StatifierUIExpressionPicklist,
};

export default StatifierUIHooks;
