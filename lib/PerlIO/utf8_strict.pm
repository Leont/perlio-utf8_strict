package PerlIO::utf8_strict;
use strict;
use warnings;

use XSLoader;

XSLoader::load(__PACKAGE__, __PACKAGE__->VERSION);

1;

#ABSTRACT: Fast and correct UTF-8 IO

__END__

=head1 SYNOPSIS

 open my $fh, '<:utf8_strict', $filename;

=head1 DESCRIPTION

This module provides a fast and correct UTF-8 PerlIO layer. Unlike perl's default C<:utf8> layer it checks the input for correctness.

=head1 LAYER ARGUMENTS

=over 4

=item allow_noncharacters

=item allow_surrogates

=back

=head1 EXPORT

PerlIO::utf8_strict exports no subroutines or symbols, just a perl layer C<utf8_strict>

=head1 DIAGNOSTICS

=over 4

=item Can't decode ill-formed UTF-8 octet sequence <%s>

(F) Encountered an ill-formed UTF-8 octet sequence. <%s> contains a hexadecimal 
representation of the maximal subpart of the ill-formed subsequence.

=item Can't interchange noncharacter code point U+%.4X

(F) Noncharacters is permanently reserved for internal use and that should 
never be interchanged. Noncharacters consist of the values U+nFFFE and U+nFFFF 
(where n is from 0 to 10^16) and the values U+FDD0..U+FDEF.

=back

