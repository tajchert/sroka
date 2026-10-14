// Test-only worker entry: the parser handler plus LibraryDO (normally in sroka-api) so LIBRARY resolves in workerd.
export { default } from "../src/index.ts";
export { LibraryDO } from "../../api/src/library-do.ts";
