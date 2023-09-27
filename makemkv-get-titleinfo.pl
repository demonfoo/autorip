use strict;
use warnings;
no autovivification qw(fetch store exists strict);
use JSON;
use English qw(-no_match_vars);

my @keys = @ARGV[0..((scalar(@ARGV) / 2) - 1)];
my @vals = @ARGV[(scalar(@ARGV) / 2)..(scalar(@ARGV) - 1)];
my %iso639_2_to_1;
@iso639_2_to_1{@vals} = @keys;

my %attrids = (
    0  => 'iaUnknown',
    1  => 'iaType',
    2  => 'iaName',
    3  => 'iaLangCode',
    4  => 'iaLangName',
    5  => 'iaCodecId',
    6  => 'iaCodecShort',
    7  => 'iaCodecLong',
    8  => 'iaChapterCount',
    9  => 'iaDuration',
    10 => 'iaDiskSize',
    11 => 'iaDiskSizeBytes',
    12 => 'iaStreamTypeExtension',
    13 => 'iaBitrate',
    14 => 'iaAudioChannelsCount',
    15 => 'iaAngleInfo',
    16 => 'iaSourceFileName',
    17 => 'iaAudioSampleRate',
    18 => 'iaAudioSampleSize',
    19 => 'iaVideoSize',
    20 => 'iaVideoAspectRatio',
    21 => 'iaVideoFrameRate',
    22 => 'iaStreamFlags',
    23 => 'iaDateTime',
    24 => 'iaOriginalTitleId',
    25 => 'iaSegmentsCount',
    26 => 'iaSegmentsMap',
    27 => 'iaOutputFileName',
    28 => 'iaMetadataLanguageCode',
    29 => 'iaMetadataLanguageName',
    30 => 'iaTreeInfo',
    31 => 'iaPanelTitle',
    32 => 'iaVolumeName',
    33 => 'iaOrderWeight',
    34 => 'iaOutputFormat',
    35 => 'iaOutputFormatDescription',
    36 => 'iaSeamlessInfo',
    37 => 'iaPanelText',
    38 => 'iaMkvFlags',
    39 => 'iaMkvFlagsText',
    40 => 'iaAudioChannelLayoutName',
    41 => 'iaOutputCodecShort',
    42 => 'iaOutputConversionType',
    43 => 'iaOutputAudioSampleRate',
    44 => 'iaOutputAudioSampleSize',
    45 => 'iaOutputAudioChannelsCount',
    46 => 'iaOutputAudioChannelLayoutName',
    47 => 'iaOutputAudioChannelLayout',
    48 => 'iaOutputAudioMixDescription',
    49 => 'iaComment',
    50 => 'iaOffsetSequenceId',
);

my %acodecmap = (
    'DTS-HD HR'   => 'dtshd',
    'DTS-HD MA'   => 'dtshd',
    'DD'          => 'ac3',
    'DTS'         => 'dts',
    'DTS Express' => 'dts',
    'TrueHD'      => 'truehd',
);

my @titles = ();

my $streamtype;
my $subtitledata;
my $audiodata;
while (<STDIN>) {
    if (m{^TINFO:(?<titlenum>\d+),(?<code>\d+),(?<attrval>\d+),"(?<string>.*)"\s*$}) {
        my ($titlenum, $code, $attrval, $string) = @{^CAPTURE}{'titlenum','code','attrval','string'};
        my $type = $attrids{$code};
        $string =~ s{^"(.*?)"$}{$1};
        if ($#titles < $titlenum) {
            $titles[$titlenum] = { 'ix' => $titlenum, 'audio' => [], 'subp' => [] };
        }

        if ($type eq 'iaDuration') {
            # aka runtime
            my ($hr, $min, $sec) = split(m{:}, $string);
            $titles[$titlenum]{length} = ($hr * 3600) + ($min * 60) + $sec;
        }
        elsif ($type eq 'iaSourceFileName') {
            # aka playlist name
            $titles[$titlenum]{playlist} = $string;
        }
        elsif ($type eq 'iaSegmentsMap') {
            # streams list
            $titles[$titlenum]{streams} = [ map { sprintf('%05d.m2ts', $_) } split(m{,}, $string) ];
        }
        elsif ($type eq 'iaOutputFileName') {
            $titles[$titlenum]{outfile} = $string;
        }
    }
    elsif (m{^SINFO:(?<arglist>.*?)\s*$}) {
        my ($titlenum, $streamnum, $code, $attrval, $string) = split(m{,}, ${^CAPTURE}{arglist});
        my $type = $attrids{$code};
        $string =~ s{^"(.*?)"$}{$1};

        if ($type eq 'iaType') {
            $streamtype = $string;

            if ($streamtype eq 'Audio') {
                if (!defined $audiodata || ${$audiodata}{ix} != $streamnum) {
                    $audiodata = { 'ix' => $streamnum };
                    push @{$titles[$titlenum]{audio}}, $audiodata;
                }
            }
            elsif ($streamtype eq 'Subtitles') {
                if (!defined $subtitledata || ${$subtitledata}{ix} != $streamnum) {
                    $subtitledata = { 'ix' => $streamnum };
                    push @{$titles[$titlenum]{subp}}, $subtitledata;
                }
            }
        }
        elsif ($type eq 'iaCodecShort') {
            if ($streamtype eq 'Video') {
                $titles[$titlenum]{codec} = $string;
            }
            elsif ($streamtype eq 'Audio') {
                ${$audiodata}{format} = $acodecmap{$string};
            }
        }
        elsif ($type eq 'iaVideoSize') {
            @{$titles[$titlenum]}{'width', 'height'} = split(m{x}, $string);
        }
        elsif ($type eq 'iaVideoAspectRatio') {
            $titles[$titlenum]{aspect} = $string;
            $titles[$titlenum]{aspect} =~ s{:}{/};
        }
        elsif ($type eq 'iaVideoFrameRate') {
            $titles[$titlenum]{fps} = (split(m{ }, $string))[0];
        }
        elsif ($type eq 'iaAudioChannelsCount') {
            ${$audiodata}{channels} = $string;
        }
        elsif ($type eq 'iaAudioSampleRate') {
            ${$audiodata}{frequency} = $string;
        }
        elsif ($type eq 'iaAudioSampleSize') {
            ${$audiodata}{samplesize} = $string;
        }
        elsif ($type eq 'iaLangCode') {
            # map back to the ISO 639-1 2-char code if possible
            $string = exists $iso639_2_to_1{$string} ? $iso639_2_to_1{$string} : $string;
            if ($streamtype eq 'Audio') {
                ${$audiodata}{langcode} = $string;
            }
            elsif ($streamtype eq 'Subtitles') {
                ${$subtitledata}{langcode} = $string;
            }
        }
        elsif ($type eq 'iaLangName') {
            if ($streamtype eq 'Audio') {
                ${$audiodata}{language} = $string;
            }
            elsif ($streamtype eq 'Subtitles') {
                ${$subtitledata}{language} = $string;
            }
        }
    }
}

print encode_json(\@titles), "\n";
