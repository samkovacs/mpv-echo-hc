# Twitch live list comes from a hand-maintained channel list, not the account's follows

`browse.lua` talks to Twitch's web GraphQL endpoint (`gql.twitch.tv/gql`, the web player's public Client-Id, `Authorization: OAuth <auth-token>` from the cookies file). Search (`searchFor`) and per-channel live status (`users(logins:) { stream {...} }`) work. Every field that would give the signed-in account's follow list does not: `currentUser.follows`, `currentUser.followedLiveUsers` and `personalSections(FOLLOWED_SECTION)` all answer `"service error"` to any client that is not Twitch's own frontend (the last one silently degrades to `POPULAR_SECTION`).

Tried and failed on 2026-09-02, so nobody repeats it: raw query; browser User-Agent plus Origin/Referer; an `/integrity` token; `X-Device-Id`; the Android and yt-dlp client ids; Helix REST with the web client id (404); and scanning the web bundles for a persisted-query hash (APQ hashes are computed client-side at runtime, there is nothing to find).

Decision: `twitch_channels=` in `script-opts/browse.conf` lists the logins to check, and `Live channels` polls them with `users(logins:)`. Comma-separated in the file; space-separated if passed via `--script-opts`, because mpv splits that option on commas.

## Considered options

- A real follow list needs a Helix user token with scope `user:read:follows` from a Twitch application the user registers, plus an OAuth flow inside mpv. Possible, not pursued; the hand list covers the actual use.

## Consequences

- This is an undocumented API. When Twitch changes it, only the Twitch section of `browse.lua` breaks; YouTube goes through yt-dlp and is unaffected.
