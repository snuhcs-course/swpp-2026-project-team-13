# App and server content ownership

- Keep the complete problem bank, difficulty metadata, MusicXML, reference images,
  sheet versions and minigame catalogs on the server. `backend/content` is the
  published source of truth. Never overwrite an existing published asset/version.
- Device/install builds are online builds by default. Do not bundle the complete
  bank to make a runtime lookup work. Fetch versioned, hash-verified content from
  the configured API instead. Prepare a selected problem before audio starts.
- The app may contain UI notation glyphs, current instrument banks, licenses and a
  small offline sample pack. Full frontend content files are development/test
  fixtures, not permission to include them in the installation package.
- Keep downloadable content in a bounded cache, shared by content hash. Keep
  handwriting, answer exports, pending saves and active attempt assets outside
  that evictable cache. Never store account data or secrets in content manifests.
- Preserve the explicit full-content simulator/test build. Verify the slim bundle
  and its sample pack as well as full-content tests when changing content loading.
- New content must update the server content manifest and relevant delivery tests.
  Update the online bundle policy only for genuine runtime/UI assets or samples.
- `.env`, tokens, database files and user uploads remain outside Git. Repository
  content and an operating server's user database are separate concerns.
