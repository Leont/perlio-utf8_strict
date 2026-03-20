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

=item allow_nonshortest

These arguments are accepted for compatibility, but currently have no effect.

=back

=head1 EXPORT

PerlIO::utf8_strict exports no subroutines or symbols, just a perl layer C<utf8_strict>

=head1 DIAGNOSTICS

=over 4

=item Can't decode ill-formed UTF-8 octet sequence <%s>

(F) Encountered an ill-formed UTF-8 octet sequence. <%s> contains a hexadecimal 
representation of the maximal subpart of the ill-formed subsequence.

=back
