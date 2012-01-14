#! perl

use strict;
use warnings;
use utf8;

use Test::More 0.88;
use Test::Exception;

use File::Spec::Functions qw/catfile/;

my $filename = catfile(qw/corpus test1.txt/);
open my $fh, '<:utf8_strict', $filename or die "Couldn't open file $filename";

my $line = <$fh>;

is($line, "Foö-Báŗ\n", 'Content is Foo-Bar with accents');

my $filename2 = catfile(qw/corpus test1-latin1.txt/);
open my $fh2, '<:utf8_strict', $filename2 or die "Couldn't open file $filename2";

throws_ok { $line = <$fh2> } qr/^Invalid unicode character at /, 'Trying to read invalidly encoded utf8 fails' or diag "Just read '$line'";

done_testing;
