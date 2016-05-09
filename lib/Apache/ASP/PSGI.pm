
package Apache::ASP::PSGI;

# this package emulates an Apache request object with a PSGI backend

use Apache::ASP;
use Apache::ASP::Request;
use Class::Struct;
use Data::Dumper;

### Use the CGI infrastructure that already exists.
use Apache::ASP::CGI::Table;

use strict;
no strict qw(refs);
use vars qw($StructsDefined @END);
$StructsDefined = 0;

### Is there really a need for this? It is a part of Apache::ASP::CGI that is
### used in testing ,psgi will probably not be used in testing anyway. --et
sub do_self {
    my $class = shift;

    if(defined($class)) {
	if(ref $class or $class =~ /Apache::ASP::PSGI/) {
	    # we called this OO style
	} else {
	    unshift(@_, $class);
	    $class = undef;
	}
    }

    my %config = @_;
    $class ||= 'Apache::ASP::PSGI';

    my $r = $class->init($0, @ARGV);
    $r->dir_config->set('CgiDoSelf', 1);
    $r->dir_config->set('NoState', 0);

    # init passed in config
    for(keys %config) {
	$r->dir_config->set($_, $config{$_});
    }

    &Apache::ASP::handler($r);

    $r;
}

sub init {
    my($class, $filename, $env, $config) = @_;
    $filename ||= $0;
    # my $logres = $env->{'psgi.errors'}->print("In init");
    # we define structs here so modperl users don't incur a runtime / memory
    unless($StructsDefined) {
	$StructsDefined = 1;
	&Class::Struct::struct( 'Apache::ASP::PSGI::connection' => 
				{
				   'remote_ip' => "\$",
				   'auth_type' => "\$",
				   'user' => "\$",
				   'aborted' => "\$",
				   'fileno' => "\$",
			       }
			       );    

	&Class::Struct::struct( 'Apache::ASP::PSGI' => 
				{
				   'connection'=> 'Apache::ASP::PSGI::connection',
				   'content_type' => "\$",
				   'current_callback' => "\$",
				   'dir_config'=>    "Apache::ASP::CGI::Table",
				   'env'       =>    "\%",
				   'filename'  =>    "\$",
				   'get_basic_auth_pw' => "\$",
				   'headers_in' =>    "Apache::ASP::CGI::Table",
				   'headers_out'=>    "Apache::ASP::CGI::Table",
				   'err_headers_out' => "Apache::ASP::CGI::Table",
				   'subprocess_env'  => "Apache::ASP::CGI::Table",
				   'method'    =>    "\$",
				   'sent_header' =>  "\$",
				   'query_string' =>  "\$",
                   ### PSGI special values that we will need
                   ### All the rest psgi things can be fetched from env() if needed.
                   'psgi_version' => "\$",
                   'psgi_input' => "\$",
                   'psgi_errors' => "\$",
                   'psgi_env'    => "\$",
			       }
			       );
    }
    # create struct
    my $self = new();
    $self->{env} = $env;
    if(!defined $env->{'psgi.version'}) {
        die "Attempt to invoke Apache::ASP PSGI in a none PSGI environment ";
    }
    ### The output from Response is collected here.
    #$self->{out} = '';
    if(exists $env->{r}){
        ### save the apache r just in case
        $self->{r} = $env->{r};
    }
    $self->{PSGI} = 1;
    $self->psgi_version($env->{'psgi.version'});
    $self->psgi_input($env->{'psgi.input'});
    $self->psgi_errors($env->{'psgi.errors'});
    $self->psgi_env($env);
    $self->query_string($env->{QUERY_STRING});
        
    $self->connection(Apache::ASP::PSGI::connection->new);
    $self->dir_config(Apache::ASP::CGI::Table->new);
    $self->err_headers_out(Apache::ASP::CGI::Table->new);
    $self->headers_out(Apache::ASP::CGI::Table->new);
    $self->headers_in(Apache::ASP::CGI::Table->new);
    $self->subprocess_env(Apache::ASP::CGI::Table->new);

    $self->filename($filename);
    $self->connection->remote_ip($env->{REMOTE_HOST} || $env->{REMOTE_ADDR} || '0.0.0.0');
    $self->connection->aborted(0);
    $self->current_callback('PerlHandler');

    # $self->headers_in->set('Cookie', $ENV{HTTP_COOKIE});
    for my $env_key ( sort keys %$env ) {
	if($env_key =~ /^HTTP_(.+)$/ or $env_key =~ /^(CONTENT_TYPE|CONTENT_LENGTH)$/) {
	    my $env_header_in = $1;
	    my $header_key = join('-', map { ucfirst(lc($_)) } split(/\_/, $env_header_in));
	    $self->headers_in->set($header_key, $env->{$env_key});
	}
    }

    # we kill the state for now stuff for now, as it's just leaving .state
    # directories everywhere you run this stuff
    ### TODO: Fix this for PSGI.
    ### If run throught Apache then we have already the needed config in r
    # object, let's copy it.If not we should think about how to read a config
    # file in PSGI.
    if(exists $self->{r}){
        my $self_dir_config = $self->dir_config;
        my $dir_conf = $self->{r}->dir_config();;
        $self->_copy_config($dir_conf);
    }
    ### The $config can be passed in as a parameter
    if($config){
        $self->_copy_config($config);
    }
    #defined($self->dir_config->get('NoState')) || $self->dir_config->set('NoState', 1);

    $self->method($env->{REQUEST_METHOD} || 'GET');

    for my $env_key ( keys %$env ) {
        $self->env($env_key, $env->{$env_key});
    }
    $self->env('SCRIPT_NAME') || $self->env('SCRIPT_NAME', $filename);

    bless $self, $class;
}

sub _copy_config{
    my ($self,$config)=@_;
    return if(!$config);
    my $self_dir_config = $self->dir_config;
    my @dir_config_keys = keys %$config;
    for my $conf_key (@dir_config_keys){
        $self_dir_config->set($conf_key => $config->{$conf_key});
    }
}

sub init_dir_config {
    my($self, %config) = @_;
    my $dir_config = $self->dir_config;
    %$dir_config = %config;
    $dir_config;
}

sub status { 
    my($self, $status) = @_;
    if(defined($status)) {
	$self->headers_out->set('status', $status);
    } else {
	$self->headers_out->get('status');
    }
}

sub cgi_env { %{$_[0]->env} ; }

sub headers_to_array{
    my($self) = @_;
    my($k, $v, $header);
    my @headers;
    my $contentType = $self->content_type();
    if($contentType){
        push @headers ,"Content-Type",$self->content_type();
    }
    for my $headers ($self->headers_out, $self->err_headers_out) {
        while(($k, $v) = each %$headers) {
            next if ($k =~ /^content\-type$/i);
            if(ref $v) {
                # if ref, then we have an array for cgi_header_out for cookies
                for my $value (@$v) {
                    $value ||= '';
                    # $header .= "$k: $value\n";
                    push @headers, $k , $value ;
                }
            } else {
                $v ||= '';
                push @headers, $k , $v ;
            }
        }
    }
    # $self->log_error("headers : ".Dumper(@headers));
    return @headers;
}

sub send_http_header {
    my($self) = @_;
    my($k, $v, $header);
    
    $self->sent_header(1);
    ### Don't print anything ,the PSGI will take the headers using
    ### headers_to_array(). --et
}

sub print { 
    my ($self,@output) = @_; 
    # eval{
    #     use Devel::StackTrace;
    #     my $trace = Devel::StackTrace->new;
    #     $self->log_error("[DEBUG] Stack Trace : ".$trace->as_string);
    #     $self->log_error("[DEBUG] OUT : ".$self->out);
    #     $self->{out} .= $trace->as_string;
    # };
    for my $data(@output){
        if(ref($data) =~ /SCALAR/){
            $self->{out} .= $$data;
        }else{
            $self->{out} .= $data;
        }
    }
}

sub send_cgi_header {
    my($self, $header) = @_;

    $self->sent_header(1);
    my(@left);
    for(split(/\n/, $header)) {
	my($name, $value) = split(/\:\s*/, $_, 2);
	if($name =~ /content-type/i) {
	    $self->content_type($value);
	} else {
	    push(@left, $_);
	}
    }

    $self->print(join("\n", @left, ''));
    $self->send_http_header();
}

sub args {
    my $self = shift;

    if(wantarray) {
        my $params = Apache::ASP::Request->ParseParams($self->query_string);
        %$params;
    } else {
        $self->query_string;
    }
}
*content = *args;

sub log_error {
    my($self, @args) = @_;
    my $server;
    if($self->{r} &&
       ($server = $self->{r}->server) &&
       $server->can('log_error')){
        ### For whatever reasont I can't get log writing into error log under
        ### apache+psgi --et
        $server->log_error(
            @args, "\n"
            );
    }else{
        $self->psgi_errors()->print(@args, "\n");
    }
}

sub get_env{
    my ($self)=@_;
    return %{$self->{env}};
}

sub register_cleanup { push(@END, $_[1]); }

# gets called when the $r get's garbage collected
sub END { 
    for ( @END ) {
	next unless $_;
	if(ref($_) && /CODE/) {
	    my $rv = eval { &$_ };
	    if($@) {
		Apache::ASP::PSGI->log_error("[ERROR] error executing register_cleanup code $_: $@");
	    }
	}
    }
}

sub soft_timeout { 1; };

sub lookup_uri {
    die('cannot call $Server->MapPath in PSGI mode');
}

sub custom_response {
    die('$Response->ErrorDocument not implemented for PSGI mode');
}

1;
