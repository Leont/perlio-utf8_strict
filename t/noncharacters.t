#! perl

use strict;
use warnings;
use utf8;

use Test::More 0.88;
use Test::Exception;
use t::Util qw[fh_with_octets pack_utf8 slurp];

my @NONCHARACTERS = (0xFDD0 .. 0xFDEF);
{
    for (my $i = 0; $i < 0x10FFFF; $i += 0x10000) {
        push @NONCHARACTERS, $i ^ 0xFFFE, $i ^ 0xFFFF;
    }
}

foreach my $cp (@NONCHARACTERS) {
    my $octets = pack_utf8($cp);
    my $name   = sprintf 'reading noncharacter U+%.4X <%s> throws an exception',
      $cp, join ' ', map { sprintf '%.2X', ord $_ } split //, $octets;

    my $fh = fh_with_octets($octets);

    throws_ok {
        slurp($fh);
    } qr/Invalid unicode character/, $name;
}

done_testing;

