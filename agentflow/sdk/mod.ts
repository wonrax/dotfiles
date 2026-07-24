/**
 * agentflow SDK — what dispatcher scripts import from a checkout of this repo.
 *
 * The implementation lives in ./standalone.ts, which is also served by the
 * daemon at http://127.0.0.1:4200/sdk.ts for scripts that import it by URL.
 * There is exactly one implementation; this module only adds the bundled
 * workflow definitions, which need the daemon's own source.
 *
 * ```ts
 * import { connect } from "../sdk/mod.ts";
 * const af = connect();
 * const { id, handle } = await af.spawn({
 *   repo: "/Users/wonrax/dev/some-repo",
 *   task: "add a --json flag to the export command",
 *   gates: "nix develop -c cargo test",
 * });
 * const conn = handle.connect();
 * conn.on("update", (t) => console.log(t.status));
 * ```
 */
export * from "./standalone.ts";
export { bundled as bundledWorkflows } from "../src/workflows.ts";
