#! perl

use strict;
use warnings;
use utf8;

use Test::More 0.88;
use Test::Exception;
use t::Util qw[fh_with_octets slurp];


my $fh = fh_with_octets("\xE2\x98\xBA" x 8092);

lives_ok { 
    my $data = do { local $/; <$fh> } 
} q[successfull reading 8092 WHITE SMILING FACE's];

done_testing;
