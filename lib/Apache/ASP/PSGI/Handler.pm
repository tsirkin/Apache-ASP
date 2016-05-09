package Apache::ASP::PSGI::Handler;
use Plack::Handler::Apache2;
use Apache::ASP;
use Apache::ASP::PSGI;

=head
    An Apache handler implementation that allows running Apache::ASP under
    mod_perl as a PSGI app.
=cut

our $c=1;
sub get_app {
    # magic!
    #&Apache::ASP::handler($r);
    ### Wrap the Apache context with Apache::ASP::PSGI one
    my ($r) = @_;
    my $filename = $r->filename();
    my $app = sub {
        my $env = shift;
        ### Run the &Apache::ASP::handler($r); get the results and put into the
        ### array result.
        my %custom_env = (r => $r,%$env);
        my $h = Apache::ASP::PSGI->init($filename, \%custom_env);
        &Apache::ASP::handler($h);
        #$c++;
        my @headers = $h->headers_to_array();
        my $status = $h->status || 200;
        return [
            $status,
            \@headers,
            # [ "Hello World" ], # or IO::Handle-like object
            #[ $h->content_type ],
            [ $h->{out}],
            ];
    };
    return $app;
}

sub handler {
    my ($r) = @_;
    $r->server->log_error(
        "In ASP PSGI Handler"
        );
    my $app = get_app($r);
    ### Just like the Plack does ,remove any mod_perl knowledge
    ### http://cpansearch.perl.org/src/MIYAGAWA/Plack-1.0034/lib/Plack/Handler/Apache2.pm
    local $ENV{MOD_PERL_API_VERSION};
    delete $ENV{MOD_PERL_API_VERSION};
    $Apache::ASP::ModPerl2 = 0;
    # print STDERR "Log usign STDERR ";
    Plack::Handler::Apache2->call_app($r, $app);
}

1;
