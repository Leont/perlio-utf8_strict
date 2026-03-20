#! perl

use strict;
use warnings;
use utf8;

use Test::More 0.88;
use Test::Exception;
use IO::Handle;
use lib 't/lib';
use Util qw[fh_with_octets pack_utf8 slurp];


my $fh = fh_with_octets("\xE2\x98\xBA" x 8092);

lives_ok { 
    my $data = do { local $/; <$fh> } 
} q[successfull reading 8092 WHITE SMILING FACE's];

{
    my $line = 'ascii';
    my ( $in, $out );
    pipe $in, $out;
    binmode $out, ':utf8_strict';
    binmode $in,  ':utf8_strict';
    print $out "...\n";
    $out->flush;
    $line .= readline $in;

    is($line, "ascii...\n", 'Appending from utf8 to ascii');
}

{
    my $octets = ("\xE2\x98\xBA" x 2730) . 'ab';
    my $fh = fh_with_octets($octets);

    is(slurp($fh), ("\x{263A}" x 2730) . 'ab',
       'Reading exactly 8192 bytes succeeds');
}

{
    my $octets = ('a' x 8191) . pack_utf8(0x00E9);
    my $fh = fh_with_octets($octets);

    is(slurp($fh), ('a' x 8191) . "\x{00E9}",
       'A valid sequence split across the 8192-byte boundary succeeds',
    );
}

{
    my $octets = ('a' x 8190) . pack_utf8(0x263A);
    my $fh = fh_with_octets($octets);

    is(slurp($fh), ('a' x 8190) . "\x{263A}",
       'A partial 3-byte sequence split across the 8192-byte boundary completes on the next fill');
}

{
    my $octets = ('a' x 8189) . pack_utf8(0x1F600);
    my $fh = fh_with_octets($octets);

    is(slurp($fh), ('a' x 8189) . "\x{1F600}",
       'A partial 4-byte sequence split across the 8192-byte boundary completes on the next fill');
}

{
    my $octets = ('a' x 8191) . "\xC3";
    my $fh = fh_with_octets($octets);

    throws_ok {
        slurp($fh);
    } qr/^Can't decode ill-formed UTF-8 octet sequence <C3> at end of file/,
      'A truncated sequence at the 8192-byte boundary reports the carried octet';
}

{
    my $octets = ('a' x 8190) . "\xF4\x80\x80";
    my $fh = fh_with_octets($octets);

    throws_ok {
        slurp($fh);
    } qr/^Can't decode ill-formed UTF-8 octet sequence <F4 80 80> at end of file/,
      'A 3-byte maximal subpart split across the 8192-byte boundary is reported in full';
}

{
    my $octets = ('a' x 8189) . pack_utf8(0x1FFFE);
    my $fh = fh_with_octets($octets);

    is(slurp($fh), ('a' x 8189) . "\x{1FFFE}",
       'A noncharacter split across the 8192-byte boundary succeeds');
}

{
    my $octets = ('a' x 8189) . pack_utf8(0x1FFFE);
    my $fh = fh_with_octets($octets, 'allow_noncharacters');

    is(slurp($fh), ('a' x 8189) . "\x{1FFFE}",
       'allow_noncharacters still accepts a noncharacter split across the 8192-byte boundary');
}


done_testing;
