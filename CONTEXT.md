# mpv echo-HC

A portable mpv install for Windows with browsing of online video sources built into the player. This glossary covers the browsing vocabulary; playback and shader terms live in the ADRs.

## Language

**Source**:
One of the places a browse view can query: YouTube, Twitch, Torrents. Each source gets its own submenu.
_Avoid_: Provider, site, backend

**View**:
One browse list a source offers, such as YouTube search or Twitch live channels. A view is one query rendered as rows.
_Avoid_: Feed, page, tab

**Entry**:
One row in a view. What the user picks to start playback.
_Avoid_: Result, item, hit

**Index**:
The torrent site the user configures the Torrents source to query, by pasting its RSS search URL into browse.conf. The repo names no index.
_Avoid_: Tracker, site name, provider

**Release**:
One torrent on the index. A release may hold a single episode or a whole season. The Torrents source's entries are releases.
_Avoid_: Video, torrent (in user-facing text), file

**Show**:
An anime title as the user thinks of it, independent of any release. Releases are grouped by show.
_Avoid_: Series, anime, title

**Followed show**:
A show in the hand-maintained list the user keeps in browse.conf. The Torrents analogue of a subscription. An index has no account here, so following is local.
_Avoid_: Subscription, watchlist, favourite

**New releases**:
The Torrents view listing the newest releases the index's feed returns, unfiltered. The analogue of YouTube Home.
_Avoid_: Front page, latest, recent

**Cover**:
The show-level artwork shown in the grid for every release of a show. Not a frame from the episode.
_Avoid_: Thumbnail (reserved for YouTube and Twitch frame images), poster
