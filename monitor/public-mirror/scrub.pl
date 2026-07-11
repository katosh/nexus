#!/usr/bin/env perl
# scrub.pl — data-driven identifier scrub for the public-mirror toolkit.
#
#   scrub.pl <mapping.tsv> <bare|angle> < input > output
#
# Reads `map` lines from the mapping file and applies them as ordered literal
# substitutions (longest-first is the caller's responsibility via file order).
# Column 3 (BARE) is used for code files; column 4 (ANGLE) for .md/.yml. This
# script hardcodes NO identifiers — the internal vocabulary lives only in the
# mapping file, which is excluded from the public mirror. That is what lets the
# public copy of this toolkit pass the same zero-leak gate as the rest of the tree.
use strict; use warnings;
my ($mapfile, $mode) = @ARGV;
die "usage: scrub.pl <mapping.tsv> <bare|angle>\n" unless $mapfile && $mode;
$mode = 'bare' unless $mode eq 'angle';
my @map;
open(my $mf, '<', $mapfile) or die "scrub.pl: cannot read $mapfile: $!\n";
while (my $l = <$mf>) {
    chomp $l;
    next if $l =~ /^\s*#/ || $l !~ /^map\t/;
    my (undef, $src, $bare, $angle) = split(/\t/, $l, 4);
    next unless defined $src && length $src;
    $angle = $bare unless defined $angle && length $angle;
    push @map, [$src, $mode eq 'angle' ? $angle : $bare];
}
close $mf;
local $/; my $t = <STDIN>;
$t = '' unless defined $t;
for my $p (@map) { my ($a,$b) = @$p; $t =~ s/\Q$a\E/$b/g; }
print $t;
