use strict;
use warnings;
no autovivification qw(fetch store exists strict);
use JSON;
use Array::Utils qw(:all);
use Data::Dumper;

my($seasonnum, $seriesinfo_file, $minlen, $audio_lang, @extra) = @ARGV;

my(@disc_paths, @disc_titlelists);

while (scalar @extra && $extra[0] ne '/==/') {
    push @disc_paths, shift @extra;
}
shift @extra;
@disc_titlelists = @extra;

open(my $seriesinfo_fh, '<', $seriesinfo_file)
        or die "Couldn't open series metadata file: $!";
my $seriesinfo = join('', <$seriesinfo_fh>);
close($seriesinfo_fh);

$seriesinfo = decode_json($seriesinfo);

foreach my $item (@disc_titlelists) {
    $item = decode_json($item);
}

if (defined $seasonnum && $seasonnum ne '') {
    # we're looking at just a single season, filter to just the episodes
    # from the season indicated
    $seriesinfo = [ map { if (${$_}{seasonNumber} == $seasonnum || (exists(${$_}{airsBeforeSeason}) && (${$_}{airsBeforeSeason} == $seasonnum) && ((${$_}{runtime} || 0) > $minlen) && (${$_}{name} =~ m{\b(?:mini-?series|pilot)\b}i) && (${$_}{name} !~ m{\bunaired\s+pilot\b}i))) { $_ } else { () } } @{${$seriesinfo}{data}{episodes}} ];
}
else {
    # we still need to filter, but only to the ones with a season number,
    # any season number, so long as it's not 0/"not a season" episodes.
    $seriesinfo = [ map { if (${$_}{seasonNumber} > 0 || (exists(${$_}{airsBeforeSeason}) && ((${$_}{runtime} || 0) > $minlen) && (${$_}{name} =~ m{\b(?:mini-?series|pilot)\b}i) && (${$_}{name} !~ m{\bunaired\s+pilot\b}i))) { $_ } else { () } } @{${$seriesinfo}{data}{episodes}} ];
}

sub round {
    my($val) = @_;

    if ($val - int($val) >= 0.5) {
        return(int($val) + 1);
    }
    return(int($val));
}

my $scalefactor = 0.25;
my $min_scalefactor = 0.10;
my $sf_multiplier = 0.95;
my $sf_discontinuity = 0;
my $double_episodes = 0;
my(@discmap, $audio_format, $audio_channels, %langset);
# these have to be stored outside the loop because they actually do have to
# persist...
my ($j, $k) = (0, 0);
EPISODE:
for (my $i = 0; $i <= $#{$seriesinfo}; $i++) {
    DISC:
    for (; $j <= $#disc_titlelists; $j++) {
        TITLE:
        for (; $k <= $#{$disc_titlelists[$j]}; $k++) {
            printf("episode offset \%d, length \%d, disc \%d, title \%d, length %d\n", $i, ${$seriesinfo}[$i]{runtime}, $j, $k, $disc_titlelists[$j][$k]{length} / 60);
            # these should already be in order from when we got them from thetvdb
            if ($double_episodes == 1 && $#{$seriesinfo} < ($i+1)) {
                $double_episodes = 0;
            }
            # only for blu rays, skip play-all title
            if (exists $disc_titlelists[$j][$k]{streams}) {
                my $streams = $disc_titlelists[$j][$k]{streams};
                my $matchcount = 0;
                my $m = $k + 1;
                my($last_l, $last_m, $l);
                # Need to match back-looking play-all titles too, c.f. "Africa",
                # "Blue Planet II"
                #if ($k == $#{disc_titlelists[$j]}) {
                if ($k > 1) {
                    for ($m = $k - 1; $m > 0; $m--) {
                        last if $disc_titlelists[$j][$m-1]{length} >= $disc_titlelists[$j][$k]{length};
                    }
                }
                STREAMCHECK:
                for ($l = 0; $l <= $#{$streams}; $l++, $m++) {
                    last STREAMCHECK if $#{$disc_titlelists[$j]} < $m;
                    last STREAMCHECK if $m == $k;
                    while (${$streams}[$l] ne $disc_titlelists[$j][$m]{streams}[0]) {
                        # there might be titles between this one and the single
                        # episode titles it contains
                        $m++;
                        last STREAMCHECK if $#{$disc_titlelists[$j]} < $m;
                        last STREAMCHECK if $m == $k;
                    }
                    # with blu-rays it's usually each episode has a one-stream
                    # playlist and the play-all strings them all together. sometimes
                    # each one has an episode followed by a half-second or so
                    # blank video clip because reasons, while the play-all title
                    # has them all strung together with a half-second insert
                    # afterward, again on account of reasons.
                    if (${$streams}[$l] eq $disc_titlelists[$j][$m]{streams}[0]) {
                        $matchcount++;
                        $last_l = $l;
                        $last_m = $m;
                        next STREAMCHECK;
                    }
                }
                if (defined $last_l && defined $last_m &&
                        $#{$streams} >= ($last_l+1) &&
                        $disc_titlelists[$j][$last_m]{streams}[1] &&
                        ${$streams}[$last_l+1] eq $disc_titlelists[$j][$last_m]{streams}[1]) {
                    # catch that last short empty clip if there is one; it's
                    # usually sourced from the same stream file.
                    $matchcount++;
                }
                #printf("\$matchcount is \%d, scalar \@{\$streams} is \%d\n", $matchcount, scalar @{$streams});
                if (abs($matchcount - scalar @{$streams}) <= 1 && $matchcount > 1) {
                    #print "looks like first title playlist matches streams from following titles, skipping play-all title\n";
                    print {*STDERR} "skipping Blu-ray Disc play-all title\n";
                    next TITLE;
                }
            }

            # blu-ray duplicate title catcher
            if (exists $disc_titlelists[$j][$k]{streams} && $k > 1) {
                for (my $l = $k - 1; $l >= 0; $l--) {
                    if ($#{$disc_titlelists[$j][$k]{streams}} == $#{$disc_titlelists[$j][$l]{streams}}) {
                        #print "stream lists are same size, check elements\n";
                        my $matchcount = 0;
                        for (my $m = 0; $m <= $#{$disc_titlelists[$j][$k]{streams}}; $m++) {
                            if ($disc_titlelists[$j][$k]{streams}[$m] eq
                                    $disc_titlelists[$j][$l]{streams}[$m]) {
                                $matchcount++;
                            }
                            else {
                                last;
                            }
                        }

                        # the last stream might not match, but ime if this happens
                        # it's an ~1 second stream with nothing in it, so who cares
                        if ($matchcount >= $#{$disc_titlelists[$j][$k]{streams}} && $matchcount >= 1) {
                            print {*STDERR} "skipping Blu-ray Disc duplicate title\n";
                            next TITLE;
                        }
                    }
                }
            }

            # dvd-specific play-all title catcher
            if (!exists $disc_titlelists[$j][$k]{streams}) {
                my $chapters = $disc_titlelists[$j][$k]{chapter};
                my $m = 0;
                my $last_m;
                PLAYALL_CANDIDATE:
                for (my $l = 0; $m <= $#{$chapters} && $l <= $#{$disc_titlelists[$j]}; $l++) {
                    # don't look at the same title
                    next if $k == $l;
                    my $new_chapters = $disc_titlelists[$j][$l]{chapter};
                    # if the title we're looking in has more chapters than our
                    # would-be "play-all" list, then it definitely can't be
                    # part of it, so just ignore.
                    next if $#{$chapters} - 1 <= $#{$new_chapters};
                    # if we get partway through and find it doesn't match, then
                    # backtrack with this...
                    $last_m = $m;
                    for (my $n = 0; $m <= $#{$chapters} && $n <= $#{$new_chapters}; $n++) {
                        # chapters are the same length, so let's move on to the next
                        if (${$chapters}[$m]{length} == ${$new_chapters}[$n]{length}) {
                            $m++;
                            next;
                        }
                        # if we're at the start of the playlist, and we got here,
                        # they didn't match, so move on to the next playlist.
                        next PLAYALL_CANDIDATE if $n == 0;
                        # last chapter is less than a second long, skip it
                        next PLAYALL_CANDIDATE if $#{$new_chapters} == $n && ${$new_chapters}[$n]{length} < 1.0;
                        # if we got here, we didn't match, and we weren't on the
                        # first element, so just backtrack and try the next title.
                        $m = $last_m;
                        next PLAYALL_CANDIDATE;
                    }
                }
                # last chapter is < 1 second, that's a gimme
                $m++ if $m == $#{$chapters} && ${$chapters}[$m]{length} < 1.0;
                #printf("\$m is \%d, scalar \@{\$chapters} is \%d\n", $m, scalar @{$chapters});
                if ($m == scalar @{$chapters}) {
                    #print "chapter list matched, speculating this is a play-all title, skipping\n";
                    print {*STDERR} "skipping DVD play-all title\n";
                    next TITLE;
                }
            }

            # only for DVDs, check for (near) duplicate title
            if (!exists $disc_titlelists[$j][$k]{streams} && $k > 0 &&
                    abs($disc_titlelists[$j][$k]{length} - $disc_titlelists[$j][$k-1]{length}) <= 1) {
                my $chapters = $disc_titlelists[$j][$k-1]{chapter};
                my $new_chapters = $disc_titlelists[$j][$k]{chapter};
                my $matchcount = 0;
                if (scalar @{$chapters} > 4 && abs(scalar(@{$chapters}) - scalar(@{$new_chapters})) <= 1) {
                    for (my $l = 0; $l <= $#{$chapters}; $l++) {
                        if ($l > $#{$new_chapters}) {
                            last;
                        }
                        if (${$chapters}[$l]{length} == ${$new_chapters}[$l]{length}) {
                            $matchcount++;
                        }
                    }
                    if ($matchcount == scalar(@{$chapters}) ||
                            $matchcount == scalar(@{$new_chapters})) {
                        #print "lengths are almost same and chapter lists are painfully similar, speculating this is a repeat title\n";
                        print {*STDERR} "skipping DVD duplicate title\n";
                        next TITLE;
                    }
                }
            }

            my %this_langset = map { ${$_}{langcode} => 1 } @{$disc_titlelists[$j][$k]{audio}};
            my @langset = keys %langset;
            my @this_langset = keys %this_langset;
            my @delta = array_diff(@langset, @this_langset);
            # the matching has to be a _bit_ fuzzy, because the metadata
            # is input by humans, and humans are notoriously unreliable.
            if (defined $audio_format) {
                # following episodes _should_ have the same audio format for
                # the first audio track... I've always observed that to be
                # the case, leastways.
                next TITLE if $audio_format ne $disc_titlelists[$j][$k]{audio}[0]{format};
                next TITLE if $audio_channels ne $disc_titlelists[$j][$k]{audio}[0]{channels};
                # the list of languages should also be (roughly) the same
                # (I've seen certain shows, like a few episodes of TNG, drop
                # a _single_ language, but out of a fairly broad set).
                next TITLE unless $#langset > 2 ? scalar(@delta) <= 1 : scalar(@delta) < 1;
            }
            # episode duration match
            my $duration_match = 0;
            my $run_delta = abs(${$seriesinfo}[$i]{runtime} - round($disc_titlelists[$j][$k]{length} / 60));
            if ($run_delta <= int(round($disc_titlelists[$j][$k]{length} / 60) * $scalefactor)) {
                # if the duration doesn't match, it needs to fall through to
                # checking for a double episode (for series like Sam and Max).
                $duration_match = 1;
            }
            if ($double_episodes == 0 && $duration_match == 1) {
                print {*STDERR} "matched\n";
                # speculating this is the right episode based on length match
                $discmap[$i] = [$j, $k];
                if ($run_delta < int(round($disc_titlelists[$j][$k]{length} / 60) * $min_scalefactor) && $sf_discontinuity == 0) {
                    # if they're particularly close, decrease $scalefactor
                    # a bit to avoid later slop
                    $scalefactor *= $sf_multiplier;
                    if ($scalefactor < $min_scalefactor) {
                        $scalefactor = $min_scalefactor;
                    }
                    #printf({*STDERR} "Adjusted scalefactor to %f\n", $scalefactor);
                }
                else {
                    # stop adjusting if we find an episode that falls outside
                    # this window
                    $sf_discontinuity = 1;
                }
                if ($i == 0) {
                    # matching the first episode audio format is generally a
                    # good indicator of whether or not it's also a legit
                    # episode.
                    $audio_format = $disc_titlelists[$j][$k]{audio}[0]{format};
                    $audio_channels = $disc_titlelists[$j][$k]{audio}[0]{channels};
                    %langset = %this_langset;
                }
                $k++;
                next EPISODE;
            }
            # definitely can't be a double episode if there's not another
            # episode in the list...
            next TITLE if $#{$seriesinfo} < ($i+1);
            # double episode length check...
            next TITLE if abs(${$seriesinfo}[$i+1]{runtime} + ${$seriesinfo}[$i]{runtime} - round($disc_titlelists[$j][$k]{length} / 60)) > 7;
            # possible double episode?
            print {*STDERR} "matched, think this is a double episode\n";
            $discmap[$i] = $discmap[$i+1] = [$j, $k];
            # usually a _first_ episode being a double is a one-off, but
            # subsequent episodes generally indicates a pattern.
            if ($i > 0) {
                $double_episodes = 1;
            }
            if ($i == 0) {
                # matching the first episode audio format is generally a
                # good indicator of whether or not it's also a legit
                # episode.
                $audio_format = $disc_titlelists[$j][$k]{audio}[0]{format};
                $audio_channels = $disc_titlelists[$j][$k]{audio}[0]{channels};
                %langset = %this_langset;
            }
            # advance it one extra because, uh, double episode, duh...
            $i++;
            $k++;
            next EPISODE;
        }
        # if we hit this point, we're off the end of the disc, it'll roll to
        # the next one, so start the title iterator from 0...
        $k = 0;
    }
}

if ($#discmap < $#{$seriesinfo}) {
    print {*STDERR} "Series/season is incomplete, I think...\n";
    exit 1
}
print {*STDERR} "Series/season _might be_ complete?\n";

# output stuff like what I'm using for process-episodes.sh so I can compare
for (my $i = 0; $i <= $#discmap; $i++) {
    my @entry;
    #$entry[0] = "disc " . ($discmap[$i][0] + 1);
    $entry[0] = $disc_paths[$discmap[$i][0]];
    $entry[0] =~ s{^/.*/}{};
    $entry[1] = $disc_titlelists[$discmap[$i][0]][$discmap[$i][1]]{ix};
    $entry[2] = '';
    if (exists $disc_titlelists[$discmap[$i][0]][$discmap[$i][1]]{playlist}) {
        $entry[2] = $disc_titlelists[$discmap[$i][0]][$discmap[$i][1]]{playlist};
        $entry[2] =~ s{^0+(\d+)\.mpls$}{$1};
    }
    $entry[3] = ${$seriesinfo}[$i]{seasonNumber};
    $entry[4] = ${$seriesinfo}[$i]{number};
    $entry[5] = '';
    print {*STDERR} (join('|', @entry)), "\n";
}

print encode_json(\@discmap), "\n";
