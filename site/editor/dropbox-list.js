// The Dropbox folder listing, kept between sync passes. A full recursive
// list_folder returns every file each time (about two per note and growing);
// list_folder/continue with the last cursor returns only what changed since,
// so a pass applies a few entries to the cached listing instead.
//
// Stored with the account (cloud.js) as
//   { cursor, files: { "<path_lower>": ["<path without leading />", rev] } }
// path_lower is the key because Dropbox paths are case-insensitive; the name
// is what sync.js sees. Data only, so tests/editor_dropbox_list_test.mjs can
// check it without a network.

const key = (name) => `/${name}`.toLowerCase();

/** A usable stored listing, or null (absent, damaged, or from an older build). */
export function storedListing(value) {
  if (!value || typeof value.cursor !== "string" || !value.cursor) return null;
  if (!value.files || typeof value.files !== "object") return null;
  return value;
}

/** An empty listing for a full list_folder; its cursor is set when the listing completes. */
export const emptyListing = () => ({ cursor: "", files: {} });

/**
 * Applies list_folder entries to `listing.files`. Returns whether anything
 * differs from what the listing held: a new file, a new revision, or a
 * deletion of something it had. Folders are not tracked.
 */
export function applyEntries(listing, entries) {
  let changed = false;
  for (const e of entries) {
    const k = e.path_lower;
    if (typeof k !== "string") continue;
    if (e[".tag"] === "file") {
      const had = listing.files[k];
      if (!had || had[1] !== e.rev) changed = true;
      listing.files[k] = [e.path_display.slice(1), e.rev];
    } else if (e[".tag"] === "deleted") {
      // A deleted folder is one entry; everything under it is gone too.
      for (const f of Object.keys(listing.files)) {
        if (f === k || f.startsWith(`${k}/`)) {
          delete listing.files[f];
          changed = true;
        }
      }
    }
  }
  return changed;
}

/** This device wrote `name` at `rev`: a later continue reporting it is not news. */
export function remember(listing, name, rev) {
  if (listing) listing.files[key(name)] = [name, rev];
}

/** This device removed `name`. */
export function forget(listing, name) {
  if (listing) delete listing.files[key(name)];
}

/** The listing as sync.js wants it: [{ name, rev }]. */
export const filesOf = (listing) => Object.values(listing.files).map(([name, rev]) => ({ name, rev }));
