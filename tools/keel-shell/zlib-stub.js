// just-bash's browser build imports node:zlib for gzip/tar. The phone has no
// zlib here, so those commands fail with a plain message instead.
const unavailable = () => { throw new Error("gzip is not available on the phone"); };
export const gunzipSync = unavailable, gzipSync = unavailable, constants = {};
