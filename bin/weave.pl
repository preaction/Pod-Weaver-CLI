#!/usr/bin/env perl
# PODNAME: weave.pl

=head1 SYNOPSIS

    weave.pl [--license <license>] [--version <version>] [--author <author>] <file>
    weave.pl -h|--help

=head1 DESCRIPTION

This program takes a path to a Perl file and runs it through
L<Pod::Weaver|Pod::Weaver>, the pluggable POD pre-processor, printing
the resulting POD to C<STDOUT>. The result can then be written to
a C<.pod> file and shipped with the Perl distribution.

=head1 ARGUMENTS

=head2 <file>

A path to a Perl file to weave.

=head1 OPTIONS

=head2 license

    weave.pl --license Perl_5 Module.pm

The name of a license to declare in the resulting POD. Should be a valid
subclass of L<Software::License>. Some examples are: C<Perl_5>,
C<GPL_1>, C<GPL_2>, C<GPL_3>, C<Artistic>. A more-complete list is
provided in L<the documentation for Software::License|Software::License>.

=head2 version

    weave.pl --version 1.23 Module.pm

The version of the input Perl file, to be used if necessary in the POD.

=head2 author

    weave.pl --author 'Doug Bell <doug@example.com>' Module.pm

The author of the Perl file. May be specified multiple times for
multiple authors. You can include an e-mail address in E<lt>E<gt>
brackets.

=head1 CONFIGURATION

C<weave.pl> expects a Pod::Weaver configuration file (C<weaver.ini>) in
the current directory.

=head1 SEE ALSO

=over 4

=item L<Pod::Weaver>

=item L<Dist::Zilla>

=back

=head1 TODO

=over 4

=item *

C<-i> in-place mode to munge the code in-place like Dist::Zilla does

=item *

C<--no-strip> to disable stripping code. This is the default in C<-i> mode.

=item *

C<< --config <file> >> to specify a path to a Pod::Weaver config file.

=item *

Use a default configuration when no C<weaver.ini> configuration file
found in the current directory.

=item *

Determine the C<--version> automatically from the input code.

=back

=head1 AUTHOR

Doug Bell <preaction@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2016 by Doug Bell <preaction@cpan.org>.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

package weave;

use v5.14;
use warnings;
use Pod::Usage qw( pod2usage );
use Getopt::Long qw( GetOptionsFromArray );
use Software::LicenseUtils;
use Module::Runtime qw( use_module );
use Scalar::Util qw( blessed );
use Pod::Weaver;
use PPI;
use Pod::Elemental;
use Encode;
use Path::Tiny qw( cwd );

__PACKAGE__->main( @ARGV ) unless caller;

sub main {
    my ( $class, @args ) = @_;

    # Check for a config and give a friendly error message if missing.
    # The default exception thrown by a missing config is very difficult
    # to understand out of context
    if ( !cwd->child( 'weaver.ini' )->is_file ) {
        die sprintf q{Cannot find Pod::Weaver config in "%s". Missing "weaver.ini" file?},
            cwd;
    }

    my %data;
    GetOptionsFromArray(
        \@args, \%data,
        'license=s',
        'version:s',
        'authors|author=s@',
    );

    if ( $data{ license } ) {
        my $license = eval { Software::LicenseUtils->new_from_short_name({
            short_name => $data{ license },
            holder => $data{ authors }[ 0 ],
        }) };
        if ( $@ ) {
            $license = eval {
                use_module( 'Software::License::' . $data{ license } )->new({
                    holder => $data{ authors }[ 0 ],
                });
            };
            if ( $@ ) {
                die "Could not load license $data{ license }: $@";
            }
        }
        $data{ license } = $license;
    }

    say _weave_module( $_, %data ) for @args;
}

# Run Pod::Weaver on the POD in the given path
sub _weave_module {
    my ( $path, %data ) = @_;

    my $perl_utf8 = Encode::encode( 'utf-8', Path::Tiny->new( $path )->slurp, Encode::FB_CROAK );
    my $ppi_document = PPI::Document->new( \$perl_utf8 ) or die PPI::Document->errstr;

    ### Copy/paste from Pod::Elemental::PerlMunger
    my $code_elems = $ppi_document->find(
        sub {
            return
                if grep { $_[ 1 ]->isa( "PPI::Token::$_" ) }
                qw(Comment Pod Whitespace Separator Data End);
            return 1;
        }
    );

    $code_elems ||= [];
    my @pod_tokens;

    my @queue = $ppi_document->children;
    while ( my $element = shift @queue ) {
        if ( $element->isa( 'PPI::Token::Pod' ) ) {
            # save the text for use in building the Pod-only document
            push @pod_tokens, "$element";
        }

        if ( blessed $element && $element->isa( 'PPI::Node' ) ) {
            # Depth-first keeps the queue size down
            unshift @queue, $element->children;
        }
    }

    ## Check for any problems, like POD inside of heredoc or strings
    my $finder = sub {
        my $node = $_[ 1 ];
        return 0
            unless grep { $node->isa( $_ ) }
        qw( PPI::Token::Quote PPI::Token::QuoteLike PPI::Token::HereDoc );
        return 1 if $node->content =~ /^=[a-z]/m;
        return 0;
    };

    if ( $ppi_document->find_first( $finder ) ) {
        warn "can't invoke Pod::Weaver on '$path': There is POD in string literals";
        return '';
    }

    my $pod_str = join "\n", @pod_tokens;
    my $pod_document = Pod::Elemental->read_string( $pod_str );

    ### MUNGE THE POD HERE!

    my $weaved_doc;
    eval {
        my $weaver = Pod::Weaver->new_from_config(
            { root => cwd },
        );
        $weaved_doc = $weaver->weave_document({
            pod_document => $pod_document,
            ppi_document => $ppi_document,
            %data
        });
    };

    if ( $@ ) {
        die sprintf q{Error weaving POD for path "%s": %s}, $path, $@;
    }

    ### END MUNGE THE POD

    my $pod_text = $weaved_doc->as_pod_string;

    #; say $pod_text;
    return $pod_text;
}


