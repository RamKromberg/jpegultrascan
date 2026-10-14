#!/usr/bin/env perl

=head1 NAME
jpegultrascan
=head1 DESCRIPTION
JPEG lossless recompressor that tries all scan possibilities to minimize size
=head1 VERSION
1.4.0 2024-04-19
=head1 LICENSE
Copyright 2015-2024 Aaron Kaluszka

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
=cut

use strict;
use warnings;
use open ':std', IO => ':raw';
use File::Spec;
use File::Temp 'tempfile';
use Getopt::Long qw(:config bundling);
use constant MAXCOEF => 63;

my $maxbits  = 3;
my $threads  = 1;
my $jpegtran = my $jpegtran2 = 'jpegtran';
my $home     = glob '~';
GetOptions
  'q'     => \my $quiet,
  'v'     => \my $verbose,
  'trace' => \my $trace,
  'i:i'   => \my $incompat,
  'j:i'   => \my @app,
  's'     => \my $strip,
  'a'     => \my $arith,
  'p=s'   => \$jpegtran,
  'o=s'   => \$jpegtran2,
  'b=i'   => \$maxbits,
  't:i'   => \$threads,
  'h|?'   => \my $help;
my @strip = my @strip2 =
  ( '-copy', defined $strip ? $strip eq 'some' ? 'comments' : 'none' : 'all' );
$arith    = defined $arith ? '-arithmetic' : '';
$verbose  = defined $verbose;
$incompat = defined $incompat ? $incompat == 0 ? 1 : $incompat : 0;
$threads  = 8  if $threads < 1;
$maxbits  = 13 if $maxbits > 13;
$maxbits  = 0  if $maxbits < 0;
$jpegtran  =~ s /^~/$home/;
$jpegtran2 =~ s /^~/$home/;

open STDOUT, '>', File::Spec->devnull if defined $quiet;
open my $STDOUT, '>&STDOUT';

@ARGV == 2 && !defined $help or die 'usage: jpegultrascan.pl [switches] inputfile outputfile
JPEG lossless recompressor that tries all scan possibilities to minimize size
Switches:
  -s       Strip all extra markers
  -s some  Strip only non-comment markers
  -i       Allow multiple planes per DC scan, which may be incompatible with
           some software
  -i -1    Disallow single scan DC components, which may be incompatible with
           some software
  -j       Strip APP0 segment for 18-byte savings (generates non-compliant JPEG
           that may be incompatible with some software)
  -j 0-14  Strip APPn segment; specify multiple times to strip different
           segments (generates JPEG that may be incompatible with some software)
  -a       Use arithmetic coding (unsupported by most software; jpegtran support
           required)
  -b 0-13  Maximum number of bit splits to test (default: 3)
  -t [N]   Number of simultaneous processes (default: 8 if specified,
           1 otherwise)
  -q       Suppress all output
  -v       Verbose output
  --trace  Output structural telemetry diagnostics and pipeline tracking keys
  -p path  Path to jpegtran (default: jpegtran)
  -o path  Path to other jpegtran (default: jpegtran)
';

my ( $fin, $fout ) = @ARGV;
$fin  =~ s /^~/$home/;
$fout =~ s /^~/$home/;
my $insize = -s $fin;
my ( undef, $ftmp ) = tempfile;
my ( undef, $jtmp ) = tempfile;
my $maxperfile = 60;
my $minchunk   = $threads;
my (
    %sizes,  $planes,  %optimal,   %optimal2,   @scans, %dcsize, %dcscans,
    @acsize, @acscans, $acallsize, $acallscans, $width, $width2
);
my ( $bestsize, $best ) = ( ~0, '' );
my ( $tran,     $tran2 );
undef $/;
$| = 1;

sub read_file($) {
    my ($file) = @_;
    open my $FILE, $file or die "Couldn't read file $file";
    my $data = <$FILE>;
    close $FILE;
    $data;
}

sub write_file($@) {
    my $file = shift;
    open my $FILE, '>', $file or die "Couldn't write file $file";
    print $FILE join '', @_;
    close $FILE;
}

sub tran(@) {
    `"$jpegtran" -optimize @_` or die;
}

sub wintran(@) {
    my ( undef, $tmp ) = tempfile SUFFIX => $$;
    system qq{"$jpegtran" -optimize @_ "$tmp"} or die;
    my $data = read_file $tmp;
    unlink $tmp;
    $data;
}

sub scansizes($) {
    my ($file) = @_;
    my @sizes;
    my $scanstart = 0;
    my $nextoff   = 0;
    while ( $file =~ /\xFF+(.)/gs ) {
        next if $+[0] < $nextoff + 2;
        my $type = ord $1;
        next unless $type;
        my $tagstart = $-[0] < $nextoff ? $nextoff : $-[0];
        my $len =
          ( $type == 216 || $type == 217 ? 0 : unpack 'n', substr $file, $+[0], 2 ) +
          $+[0] -
          $tagstart;
        $nextoff = $tagstart + $len;
        if ($scanstart) {
            $sizes[$#sizes] += $tagstart - $scanstart;
            last if $type == 217;
            push @sizes, $len;
            $scanstart = 0;
        } elsif ( !@sizes && 192 <= $type <= 207 && $type != 196 && $type != 200 && $type != 204 ) {
            push @sizes, 0;
        } elsif (@sizes) {
            $sizes[$#sizes] += $len;
        }
        $scanstart = $tagstart + $len if $type == 218;
    }
    @sizes;
}

sub transcan($$) {
    my ( $start, $end ) = @_;
    my ( undef,  $tmp ) = tempfile SUFFIX => $$;
    my @sizes;
    for my $i ( $start .. $end ) {
        write_file $tmp, @{ $scans[$i] };
        my $data = &$tran( '-scans', "\"$tmp\"", $arith, "\"$jtmp\"" );
        if ( length $data == 0 ) {
            print STDERR "\nNo data returned for:\n", join '', @{ $scans[$i] };
            next;
        }
        my @sizesi = scansizes $data;
        if ( $#sizesi != $#{ $scans[$i] } ) {
            print STDERR "\nIncorrect encoding for:\n", join '', @{ $scans[$i] };
            next;
        }
        if ($verbose) {
            for ( 0 .. $#sizesi ) {
                my $scan = @{ $scans[$i] }[$_];
                unless ( defined $sizes{$scan} ) {
                    $sizes{$scan} = $sizesi[$_];
                    chop $scan;
                    printf $STDOUT "%-${width}s %${width2}d\n", $scan, $sizesi[$_];
                }
            }
        } else {
            print $STDOUT '.';
        }
        push @sizes, $i, @sizesi;
    }
    unlink $tmp;
    @sizes;
}

sub pipefork() {
    pipe my $parent, my $child or die "Couldn't pipe\n";
    my $pid = fork;
    die "fork failed: $!" unless defined $pid;
    if ($pid) {
        close $child;
    } else {
        close $parent;
        close STDOUT;
        open STDOUT, '>&=', fileno $child or die "Couldn't open STDOUT\n";
    }
    ( $parent, $pid );
}

sub doscans() {
    if ( $threads == 1 || $#scans < $minchunk ) {
        my @sizes = transcan 0, $#scans;
        unless ($verbose) {
            for ( my $i = 0 ; $i < $#sizes ; ++$i ) {
                $sizes{$_} = $sizes[ ++$i ] for @{ $scans[ $sizes[$i] ] };
            }
        }
    } else {
        my $chunk = int @scans / $threads;
        $chunk = $minchunk if $chunk < $minchunk;
        my $end = scalar @scans;
        my @fh;
        for ( my $start = 0 ; $start < $end ; $start += $chunk ) {
            my ( $fh, $pid ) = pipefork;
            unless ($pid) {
                print join ',', transcan $start,
                  ( $start + $chunk < $end - $minchunk ? $start + $chunk : $end ) - 1;
                exit;
            }
            push @fh, $fh;
        }
        for (@fh) {
            my @sizes = split ',', <$_>;
            for ( my $i = 0 ; $i < $#sizes ; ++$i ) {
                $sizes{$_} = $sizes[ ++$i ] for @{ $scans[ $sizes[$i] ] };
            }
        }
    }
    @scans = ();
}

sub queuescans(@) {
    push @scans, \@_;
}

sub queuescansmulti(@) {
    my ( @dc, @ac );
    for ( my $i = 0 ; $i < @_ ; ++$i ) {
        if ( @dc + @ac > $maxperfile ) {
            do {
                pop @ac;
                --$i;
            } while $ac[$#ac] !~ / 0;\n$/;
            queuescans @dc, @ac;
            @ac = ();
        }
        if ( $_[$i] =~ /: 0 0/ ) {
            push @dc, splice @_, $i, 1;
            --$i;
        } else {
            push @ac, $_[$i];
        }
    }
    queuescans @dc, @ac if @ac > 0;
}

sub generatebitscans($$$$) {
    my ( $plane, $a, $b, $numbits ) = @_;
    my @scans = "$plane: $a $b 0 $numbits;\n";
    for ( my $i = $numbits ; $i > 0 ; --$i ) {
        push @scans, "$plane: $a $b $i " . ( $i - 1 ) . ";\n";
    }
    @scans;
}

sub generatedcscans($) {
    my ($plane)   = @_;
    my $allplanes = join ' ', 0 .. $planes;
    my $dummy;
    if ( $plane ne $allplanes ) {
        $dummy = $allplanes;
        $dummy =~ s /$_ ?// for split ' ', $plane;
        $dummy =~ s /^(.*?) ?$/$1: 0 0 0 9;\n/;
    }
    for ( 0 .. $maxbits ) {
        my @scans = generatebitscans $plane, 0, 0, $_;
        push @scans, $dummy if $dummy;
        queuescans @scans;
    }
}

sub generateacscans($) {
    my ($plane) = @_;
    my $dummy = join( ' ', 0 .. $planes ) . ": 0 0 0 9;\n";
    for ( 0 .. MAXCOEF - 1 ) {
        for my $offset ( 0 .. ( $_ < MAXCOEF - 1 - $_ ? $_ : MAXCOEF - 1 - $_ ) ) {
            for ( my $numbits = 0 ; $numbits <= $maxbits ; ++$numbits ) {
                my @scans = $dummy;
                push @scans, generatebitscans $plane, 1, $offset, $numbits if $offset > 0;
                my $i = $offset + 1;
                for ( ; $i + $_ < MAXCOEF ; $i += $_ + 1 ) {
                    push @scans, generatebitscans $plane, $i, $i + $_, $numbits;
                }
                push @scans, generatebitscans $plane, $i, MAXCOEF, $numbits if $i <= MAXCOEF;
                @scans <= $maxperfile ? queuescans @scans : queuescansmulti @scans;
            }
        }
    }
}

sub choosebest($$$$) {
    my ( $leftsize, $left, $rightsize, $right ) = @_;
    return if !$leftsize && !$rightsize;
    return ( $leftsize, $left ) if !$rightsize || $leftsize && $leftsize < $rightsize;
    return ( $rightsize, $right )
      if !$leftsize
      || $rightsize && $leftsize > $rightsize
      || scalar( () = $left =~ /\n/g ) > scalar( () = $right =~ /\n/g );
    ( $leftsize, $left );
}

sub trybitsplits($$$$$);

sub trybitsplits($$$$$) {
    my ( $plane, $a, $b, $c, $d ) = @_;
    my $key = "$plane $a $b $c $d";
    unless ( $optimal2{$key} ) {
        my $minscans = "$plane: $a $b $c $d;\n";
        my $minsize  = $sizes{$minscans};
        for ( $a .. $b - 1 ) {
            my ( $asize, $ascans ) = trybitsplits $plane, $a, $_, $c, $d;
            my ( $bsize, $bscans ) = trybitsplits $plane, $_ + 1, $b, $c, $d;
            ( $minsize, $minscans ) = choosebest $asize + $bsize, $ascans . $bscans, $minsize,
              $minscans;
        }
        $optimal2{$key} = [ $minsize, $minscans ];
    }
    @{ $optimal2{$key} };
}

sub trysplits($$$);

sub trysplits($$$) {
    my ( $plane, $a, $b ) = @_;
    my $key = "$plane $a $b";
    unless ( $optimal{$key} ) {
        my ( $minsize, $minscans ) = ( ~0, '' );
        for ( 0 .. $maxbits ) {
            my ( $allsize, $allscans ) = trybitsplits $plane, $a, $b, 0, $_;
            for ( my $i = $_ ; $i > 0 ; --$i ) {
                my ( $size, $scans ) = trybitsplits $plane, $a, $b, $i, $i - 1;
                $allsize += $size;
                $allscans .= $scans;
            }
            ( $minsize, $minscans ) = choosebest $allsize, $allscans, $minsize, $minscans;
        }
        for ( $a .. $b - 1 ) {
            my ( $asize, $ascans ) = trysplits $plane, $a, $_;
            my ( $bsize, $bscans ) = trysplits $plane, $_ + 1, $b;
            ( $minsize, $minscans ) = choosebest $asize + $bsize, $ascans . $bscans, $minsize,
              $minscans;
        }
        $optimal{$key} = [ $minsize, $minscans ];
    }
    @{ $optimal{$key} };
}

sub appremove($$) {
    my ( $file, $n ) = @_;
    my $tag = pack 'CC', 255, 224 + $n;
    while ( $tag eq substr $file, 2, 2 ) {
        my $size = 2 + unpack 'n', substr $file, 4, 2;
        substr $file, 2, $size, '';
        print $verbose ? "\nRemoved $size APP$n bytes.\n" : '.';
    }
    $file;
}

sub partitionscans($@);

sub partitionscans($@) {
    my $offset = shift;
    my ( $dcallsize, $dcallscans ) = ( 0, '' );
    for (@_) {
        unless ( defined $dcsize{$_} ) {
            generatedcscans $_;
            doscans;
            ( $dcsize{$_}, $dcscans{$_} ) = trysplits $_, 0, 0;
        }
        $dcallsize += $dcsize{$_};
        $dcallscans .= $dcscans{$_};
    }
    ( $bestsize, $best ) = choosebest $dcallsize + $acallsize, $dcallscans . $acallscans,
      $bestsize, $best;
    my @all = map "$_;\n", @_;
    for (@all) {
        unless ( defined $sizes{$_} ) {
            queuescans @all;
            doscans;
            last;
        }
    }
    my $allsize = 0;
    for (@all) {
        $allsize += $sizes{$_} if $sizes{$_};
    }
    ( $bestsize, $best ) = choosebest $allsize, join( '', @all ), $bestsize, $best;
    for my $i ( $offset .. $#_ ) {
        for ( $i + 1 .. $#_ ) {
            $_[$offset] =~ /(\d+)$/;
            next if $_[$_] < $1;
            my @newpartition = @_;
            $newpartition[$i] .= ' ' . splice @newpartition, $_, 1;
            partitionscans $i, @newpartition;
        }
    }
}

my $data = read_file $fin;
$maxbits = 10 if $maxbits > 10 && $data =~ /\xFF[\xC0-\xC3\xC5-\xC7\xC9-\xCB\xCD-\xCF]..\x08/s;
my $hasicc =
  $data =~ /\xFF\xE2(..)ICC_PROFILE/s && substr( $data, $+[0], unpack 'n', $1 ) !~ /desc.+sRGB/s;
$data      = `"$jpegtran" -? 2>&1`;
$tran      = $data =~ /outputfile/ ? \&wintran : \&tran;
$strip[1]  = $data =~ /copy icc/ ? 'icc' : 'all' if $hasicc && $strip[1] ne 'all';
$data      = `"$jpegtran2" -? 2>&1`;
$strip2[1] = $data =~ /copy icc/ ? 'icc' : 'all' if $hasicc && $strip2[1] ne 'all';

if ( $data =~ /outputfile/ ) {
    $data  = `"$jpegtran2" -v @strip2 -optimize "$fin" "$jtmp" 2>&1`;
    $tran2 = \&wintran;
} else {
    open my $OLDERR, '>&', STDERR;
    open STDERR,     '>',  $ftmp;
    open my $TRAN,   '-|', $jpegtran2, '-v', @strip2, '-optimize', $fin;
    $data = <$TRAN>;
    close $TRAN;
    open STDERR, '>&', $OLDERR;
    write_file $jtmp, $data;
    $data  = read_file $ftmp;
    $tran2 = \&tran;
}
$data =~ /components=(\d+)/ or die "Couldn't read file";
$planes = $1 - 1;
$width  = ( $planes + 1 ) * 2 + 10;
$width2 = length $insize;

if ($trace) {
    print "[TRACE_MATRIX_DUMP_START]\n";
    print "=== PERL REFERENCE COST HASH PROFILE DUMP ===\n";
    for my $key ( sort keys %sizes ) {
        if ( $key =~ /^(\d+):\s*(\d+)\s+(\d+)\s+0\s+(\d+)/ ) {
            my ( $p, $ss, $se, $al ) = ( $1, $2, $3, $4 );
            my $span = $se - $ss + 1;
            print "MATRIX_CELL | P:$p | Ss:", sprintf( "%02d", $ss ), " | Se:",
              sprintf( "%02d", $se ), " | Span:$span | Al:", sprintf( "%02d", $al ),
              " | Cost:$sizes{$key}\n";
        }
    }
    print "=============================================\n";
    print "[TRACE_MATRIX_DUMP_END]\n";
}

for ( 0 .. $planes ) {
    print "Calculating sizes of AC scans, plane $_\n";
    generateacscans $_;
    doscans;
    print "\nSearching for best AC scan, plane $_\n";
    ( $acsize[$_], $acscans[$_] ) = trysplits $_, 1, MAXCOEF;
    $acallsize += $acsize[$_];
    $acallscans .= $acscans[$_];
    print "Best AC scan, plane $_:\n$acscans[$_]Size: $acsize[$_]\n\n" if $verbose;
}

if ($trace) {
    print "=== PERL REFERENCE COST HASH PROFILE DUMP ===\n";
    for my $key ( sort keys %sizes ) {
        if ( $key =~ /^(\d+):\s*(\d+)\s+(\d+)\s+0\s+(\d+);/ ) {
            my ( $p, $ss, $se, $al ) = ( $1, $2, $3, $4 );
            my $span = $se - $ss + 1;
            print "MATRIX_CELL | P:$p | Ss:", sprintf( "%02d", $ss ), " | Se:",
              sprintf( "%02d", $se ), " | Span:$span | Al:", sprintf( "%02d", $al ),
              " | Cost:$sizes{$key}\n";
        }
    }
    print "=============================================\n";
}

print "Calculating sizes and searching for best DC scan\n";
if ( $incompat > 0 && $planes > 1 ) {
    partitionscans 0, 0 .. $planes;
} else {
    partitionscans $planes + 1, 0 .. $planes if $planes > 0 && $incompat >= 0;
    partitionscans 2, join ' ', 0 .. $planes;
}
if ($verbose) {
    my $dcallscans = $best;
    $dcallscans =~ s/$acallscans//;
    print "\nBest DC scan:\n${dcallscans}Size: ", $bestsize - $acallsize, "\n"
      if $verbose && $dcallscans ne $best;
}

$best = join "\n", sort {
    my $pattern = qr/^([^:]*)(?:: (\d+) (\d+) \d+ (\d+))?/;
    my ( $ap, $aa, $ab, $ad ) = $a =~ /$pattern/g;
    my ( $bp, $ba, $bb, $bd ) = $b =~ /$pattern/g;
    !defined $ab || !defined $bb ? $ap cmp $bp : $ab <=> $bb || $ap cmp $bp
} split "\n", $best;

my @best = map { [/^([^:]*)(?:: (\d+) (\d+) \d+ (\d+))?/g] } split "\n", $best;

my @prev = ();
for my $i ( 0 .. $#best ) {
    for my $j ( 0 .. $#best ) {
        next if $i == $j;
        push @{ $prev[$j] },
          $i
          if (
            (
                $best[$j][0] eq $best[$i][0]
                && (   $best[$i][1] <= $best[$j][1] <= $best[$i][2]
                    || $best[$j][1] <= $best[$i][1] <= $best[$j][2] )
                && $best[$i][3] > $best[$j][3]
            )
            || ( $best[$j][0] gt $best[$i][0] && $best[$j][2] >= $best[$i][2] )
          );
    }
}

my $i       = -1;
my @bestout = ();
my %bestout = ();
loop: while ( @bestout < @best ) {
    $i = 0 if ++$i == @best;
    next   if defined $bestout{$i};
    for ( @{ $prev[$i] } ) {
        next loop unless defined $bestout{$_};
    }
    push @bestout, $i;
    $bestout{$i} = 1;
    $i = -1;
}
$best = join "\n", ( split "\n", $best )[@bestout];

# --- UNIFIED TELEMETRY PASS: FIXED POINTER INTERPOLATION AND TRAILING WHITESPACE ---
if ($trace) {
    print "[TRACE_FINAL_SCRIPT_START]\n";
    print "=== FINAL PERL JPEGULTRASCAN SCRIPT DUMP ===\n";

    my @lines = split "\n", $best;
    for my $idx ( 0 .. $#lines ) {
        my $line = $lines[$idx];

        if ( $line =~ /^([^:]+):\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+);/ ) {
            print "SCAN $idx: Comps=1, Component_Idx_0=$1, Ss=$2, Se=$3, Ah=$4, Al=$5\n";
        } elsif ( $line =~ /^([^:]+):\s*0\s+0\s+0\s+9;/ || $line =~ /^([^:]+):\s*0\s*0\s*0\s*9;/ ) {
            print "SCAN $idx: Comps=1, Component_Idx_0=$1, Ss=0, Se=0, Ah=0, Al=9\n";
        } else {
            my ( $comps_str, $params ) = split ':', $line;
            my @c_list = split ' ', $comps_str;
            my $num_c  = scalar @c_list;
            if ( $params =~ /\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+);/ ) {
                print
"SCAN $idx: Comps=$num_c, Component_Idx_0=$comps_str, Ss=$1, Se=$2, Ah=$3, Al=$4\n";
            }
        }
    }

    print "=============================================\n";
    print "[TRACE_FINAL_SCRIPT_END]\n";
}

# ----------------------------------------------------------------------------

write_file $ftmp, $best;
$data = &$tran( '-scans', "\"$ftmp\"", $arith, @strip, "\"$jtmp\"" );
$data = appremove $data, $_ for @app;

if ( $jpegtran ne $jpegtran2 ) {
    $jpegtran = $jpegtran2;
    my $data2 = &$tran2( '-scans', "\"$ftmp\"", $arith, @strip2, "\"$jtmp\"" );
    $data2 = appremove $data2, $_ for @app;
    $data  = $data2 if length $data2 && length $data2 < length $data;
}

if ($trace) {
    print "[TRACE_BINARY_STRUCTURE_START]\n";
    print "CONTAINER_PROPERTIES: TotalBytes=" . length($data) . "\n";

    my $pos                  = 2;
    my $size                 = length($data);
    my $scan_counter         = 0;
    my $current_scan_payload = 0;
    my $inside_scan_payload  = 0;

    while ( $pos < $size ) {
        my $raw_byte = substr( $data, $pos, 1 );
        if ( ord($raw_byte) == 0xFF ) {
            my $next_idx = $pos + 1;
            while ( $next_idx < $size && ord( substr( $data, $next_idx, 1 ) ) == 0xFF ) {
                $pos++;
                $next_idx = $pos + 1;
            }
            if ( $next_idx >= $size ) { last; }

            my $marker = ord( substr( $data, $next_idx, 1 ) );
            if ( $marker == 0x00 ) {
                $current_scan_payload += 2 if $inside_scan_payload;
                $pos                  += 2;
                next;
            }

            if ($inside_scan_payload) {
                print "SCAN_ENTROPY_BODY [$scan_counter]: PayloadBytes=$current_scan_payload\n";
                $current_scan_payload = 0;
                $inside_scan_payload  = 0;
                $scan_counter++;
            }

            my $marker_length = 0;
            if ( $marker != 216 && $marker != 217 && ( $marker < 208 || $marker > 215 ) ) {
                if ( $pos + 3 < $size ) {
                    $marker_length = unpack( 'n', substr( $data, $pos + 2, 2 ) );
                }
            }

            if (   192 <= $marker
                && $marker <= 207
                && $marker != 196
                && $marker != 200
                && $marker != 204 )
            {
                my $sof_type = $marker - 192;
                print "MARKER_NODE: Type=SOF$sof_type(0x"
                  . sprintf( "%02X", $marker )
                  . ") | SegmentBytes=$marker_length\n";
            } elsif ( $marker == 196 ) {
                print "MARKER_NODE: Type=DHT(0xC4) | SegmentBytes=$marker_length\n";
            } elsif ( $marker == 219 ) {
                print "MARKER_NODE: Type=DQT(0xDB) | SegmentBytes=$marker_length\n";
            } elsif ( $marker == 221 ) {
                print "MARKER_NODE: Type=DRI(0xDD) | SegmentBytes=$marker_length\n";
            } elsif ( $marker == 218 ) {
                print "MARKER_NODE: Type=SOS(0xDA) | SegmentBytes=$marker_length\n";
                $inside_scan_payload = 1;
                $pos += ( 2 + $marker_length );
                next;
            } elsif ( 224 <= $marker && $marker <= 239 ) {
                my $app_type = $marker - 224;
                print "MARKER_NODE: Type=APP$app_type(0x"
                  . sprintf( "%02X", $marker )
                  . ") | SegmentBytes=$marker_length\n";
            } elsif ( $marker == 254 ) {
                print "MARKER_NODE: Type=COM(0xFE) | SegmentBytes=$marker_length\n";
            } elsif ( $marker == 217 ) {
                print "MARKER_NODE: Type=EOI(0xD9) | SegmentBytes=0\n";
            } else {
                print "MARKER_NODE: Type=UNKNOWN(0x"
                  . sprintf( "%02X", $marker )
                  . ") | SegmentBytes=$marker_length\n";
            }

            $pos += ( $marker_length > 0 ? $marker_length + 2 : 2 );
        } else {
            $current_scan_payload++ if $inside_scan_payload;
            $pos++;
        }
    }
    print "[TRACE_BINARY_STRUCTURE_END]\n";
}

my $size = length $data;
print "\nBest scans:\n$best\nSize: $size bytes\n";
printf "Change: %+.6f%%\n", ( $size / $insize - 1 ) * 100;

if ( $size && $size <= $insize ) {
    write_file $fout, $data;
} elsif ( $fin ne $fout ) {
    write_file $fout, read_file $fin;
}
unlink $ftmp, $jtmp;
