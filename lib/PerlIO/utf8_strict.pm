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

This module provides a fast and correct UTF-8 PerlIO layer.

=head1 SYNTAX

The general syntax of the layer is in the form:

 :utf8_strict

