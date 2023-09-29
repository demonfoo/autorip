## autorip

This is a tool (intended to be cross-platform for anything with `bash`)
to handle all the following tasks:

* Ripping discs (via `dvdbackup` for DVDs, or `makemkvcon` for Blu-ray
  Discs and UltraHD Blu-ray Discs, if you have it and are on a supported
  OS).
* Guessing the series, season (as applicable) and disc number(s) based
  on volume labels, or prompting for the necessary info (which it doesn't
  have to do _often_, but it will when needed).
* Getting TV show metadata via [TheTVDB](https://www.thetvdb.com/). (This
  does require you to have an account, because that's how they work now.)
* Mapping titles from the disc(s) to episodes.
* Remuxing/transcoding episodes from discs to a
  [Plex](https://plex.tv/)-friendly file structure.

Much of the above is at least mostly working. Remuxing/transcoding is
currently still very much a work-in-progress, but I am actively working
toward making it happen.

This requires the following tools:

* `curl` - for talking to TheTVDB.
* `jq` - for parsing/manipulating JSON from various sources.
* `lsdvd` - I think the name says it all.
* `python-yq` - needed for using `lsdvd`'s XML output mode and transforming
  the output into JSON.
* `dvdbackup` - I think the name says it all.
* `lsof` - for checking on `dvdbackup`'s progress.
* [MakeMKV](https://www.makemkv.com/) - optional, but needed for ripping
  Blu-ray Discs. So if you intend to do it...
* `udftools` - needed for identifying Blu-ray Discs.
* `smartmontools` - Only needed on OpenBSD, because it lacks other tools for
  inquiring for optical drive information.
* Perl - several processing filters are implemented in it.
* Perl `JSON` module - you know, for kids!
* Perl `Array::Utils` module - for some data structure processing tasks.


## Known issues

There are series/seasons that I know there are issues with:

* _Terminator: The Sarah Connor Chronicles_ Season 1. Many episodes don't have their own titles, and are just tossed together. Will look for a solution.
* _Fringe_ Season 1: Same as above. (Dear Warner Bros: This is bad authoring.)
* _Terminator: The Sarah Connor Chronicles_ Season 2. A few episodes don't have their own titles. Looking for a solution.
* _Fringe_ Season 2: Same as above.

More will likely be added, but the _vast_ majority of seasons I own on disc
work, so most should more generally.
