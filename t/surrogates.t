#! perl

use strict;
use warnings;
use utf8;

use Test::More 0.88;
use Test::Exception;
use t::Util qw[fh_with_codepoints slurp];

my @SURROGATES = (0xD800 .. 0xDFFF);

foreach my $cp (@SURROGATES) {
    my $fh = fh_with_codepoints($cp);

    my $name = sprintf 'reading encoded surrogate U+%.4X throws an exception', $cp;

    throws_ok {
        slurp($fh);
    } qr/Invalid unicode character/, $name;
}

done_testing;

