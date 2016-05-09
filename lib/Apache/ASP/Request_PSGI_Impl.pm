
package Apache::ASP::Request;
use Data::Dumper;
use Apache::ASP::Collection;
use strict;

sub new {
    my $asp = shift;
    my $r = $asp->{r};

    my $self = bless 
      { 
       asp => $asp,
       all_content_read => 0,### did we already the input stream to the content
#       content => undef,
#       Cookies => undef,
#       FileUpload => undef,
#       Form => undef,
#       QueryString => undef,
#       ServerVariables => undef,
       Method => $r->method || 'GET',
       TotalBytes => 0,
      };

    # calculate whether to read POST data here
    my $request_binary_read = &config($asp, 'RequestBinaryRead', undef, 1);
    $asp->{request_binary_read} = $request_binary_read;

    # set up the environment, including authentication info
    my $env = { %{$r->subprocess_env}, %ENV };
    if($r->{PSGI}){
        $env = { %$env, $r->get_env() };
    }

    if(&config($asp, 'AuthServerVariables')) {
	if(defined $r->get_basic_auth_pw) {
	    my $c = $r->connection;
	    #X: this needs to be extended to support Digest authentication
	    $env->{AUTH_TYPE} = $c->auth_type;
	    $env->{AUTH_USER} = $c->user;
	    $env->{AUTH_NAME} = $r->auth_name;
	    $env->{REMOTE_USER} = $c->user;
	    $env->{AUTH_PASSWD} = $r->get_basic_auth_pw;
	}
    }
    $self->{'ServerVariables'} = bless $env, 'Apache::ASP::Collection';

	my $r = $asp->{r};
    # assign no matter what so Form is always defined
    my $form = {};
    my %upload;
    my $headers_in = $self->{asp}{headers_in};
    if($self->{Method} eq 'POST' and $request_binary_read) {
        $self->{TotalBytes} = defined($ENV{CONTENT_LENGTH}) ? $ENV{CONTENT_LENGTH} : $headers_in->get('Content-Length');
        if($headers_in->get('Content-Type') =~ m|^multipart/form-data|) {
            # return (error => 0,processed => 0,form => \%form, upload => \%uploads);;
            my %parseRes = $self->_ParseMultipart($asp);
            $asp->{dbg} && $asp->Debug("parseRes : ".Dumper(%parseRes)."\n");
            if($parseRes{error}){
                $self->{asp}->Error("Parsing upload request failed : $@");
            }elsif(!$parseRes{processed}){
                $self->{asp}->Debug("Parsing multipart skipped, use BinaryRead".
                                    "to get the content of the request. If this".
                                    "is not what you have expected check if you didn't disabled file upload by setting".
                                    "FileUploadProcess to 0 and check that you".
                                    "use PSGI or CGI");
            }else{
                %upload = %{$parseRes{upload}};
                $form = $parseRes{form};
            }
        } else {
            # Only tie to STDIN if we have cached contents
            # don't untie *STDIN until DESTROY, so filtered handlers
            # have an opportunity to use any cached contents that may exist
            if(my $len = $self->{TotalBytes}) {
                $self->{content} = $self->BinaryRead($len) || '';
                $self->{all_content_read} = 1;
                tie(*STDIN, 'Apache::ASP::Request', $self);
                #AJAX POSTs are ``application/x-www-form-urlencoded; charset=UTF-8'' in Firefox3+
                #by Richard Walsh Nov 25, 2008 (found in nabble)
                if($headers_in->get('Content-Type') =~ m|^application/x-www-form-urlencoded|) {
                    $form = &ParseParams($self, \$self->{content});
                } else {
                    $form = {};
                }
            }
        }
    }

ASP_REQUEST_POST_READ_DONE:

    $self->{'Form'} = bless $form, 'Apache::ASP::Collection';
    $self->{'FileUpload'} = bless \%upload, 'Apache::ASP::Collection';
    my $query = $r->args();
    my $parsed_query = $query ? &ParseParams($self, \$query) : {};
    $self->{'QueryString'} = bless $parsed_query, 'Apache::ASP::Collection';

    if(&config($asp, 'RequestParams')) {
	$self->{'Params'} = bless { %$parsed_query, %$form }, 'Apache::ASP::Collection';
    } 

    # do cookies now
    my %cookies; 
    if(my $cookie = $headers_in->get('Cookie')) {
	my @parts = split(/;\s*/, ($cookie || ''));
	for(@parts) {	
	    my($name, $value) = split(/\=/, $_, 2);
	    $name = &Unescape($self, $name);
	    
	    next if ($name eq $Apache::ASP::SessionCookieName);
	    next if $cookies{$name}; # skip dup's
	    
	    $cookies{$name} = ($value =~ /\=/) ? 
	      &ParseParams($self, $value) : &Unescape($self, $value);
	}
    }
    $self->{Cookies} = bless \%cookies, 'Apache::ASP::Collection';

    $self;
}

sub _IsUploadEnabled{
    my ($self,$asp)=@_;
    $asp->{file_upload_process} = &config($asp, 'FileUploadProcess', undef, 1);
    if(!$asp->{file_upload_process}){
        $self->{asp}->Debug("FileUploadProcess is disabled, file upload data in \$Request->BinaryRead");
    }
    return $asp->{file_upload_process};
}

sub _ParseMultipartPSGI{
    my ($self,$asp)=@_;
    if(!$self->_IsUploadEnabled($asp)) {
        return (error => 0,processed => 0,form => {}, upload => {});;
    }
    for my $unSupported(qw/FileUploadTemp FileUploadMax /){
        my $isSet = &config($asp, $unSupported, undef, 1);
        if($isSet){
            $self->{asp}->Error("$unSupported $isSet configuration is unsupported by PSGI");
        }
    }
    
	my $r = $asp->{r};
    use Plack::Request;
    my $psgiRequest = Plack::Request->new($r->psgi_env);
    
    # $asp->{dbg} && $asp->Debug("psgi_env : ".Dumper($r->psgi_env));
    # $asp->{dbg} && $self->{asp}->Debug("psgiRequest :
    # ".Dumper($psgiRequest)."\n");
    if($asp->{dbg}){
        $asp->Debug("CONTENT_TYPE : ".$psgiRequest->env->{CONTENT_TYPE}."\n");
        $asp->Debug("CONTENT_LENGTH : ".$psgiRequest->env->{CONTENT_LENGTH}."\n");
    }
    ### returns Hash::MultiValue
    my $psgiUploads = $psgiRequest->uploads();
    $asp->{dbg} && 
        $self->{asp}->Debug("psgiUploads :".Dumper($psgiUploads)."\n");
    $asp->{dbg} && 
        $self->{asp}->Debug("psgiUploads keys : ".Dumper($psgiUploads->keys)."\n");
    my %uploads;
    my %form;
    for my $paramName($psgiUploads->keys){
        ### Note that that unlike PSGI, asp stores the uploads in hash of
        ### hashes, so multiple upload of the same name are impossible.
        $asp->{dbg} && $self->{asp}->Debug("Reading param $paramName \n");
        my $psgiUpload = $psgiUploads->{$paramName};
        ### unlike in cgi uploadInfo is not available here.
        $uploads{$paramName}{BrowserFile} = $psgiUpload->path;
        $uploads{$paramName}{ContentType} = $psgiUpload->content_type;
        ### as per PSGI the file is always saved on disk
        $form{$paramName}{TempFile} = $psgiUpload->path;
        ### The is no file handle by default, should we create one?
        my $fh = IO::File->new($psgiUpload->path);
        $uploads{$paramName}{FileHandle} = $fh;
        $form{$paramName} = bless $uploads{$paramName}, 'Apache::ASP::Collection';
    }    
    my $bodyParameters = $psgiRequest->body_parameters();
    $asp->{dbg} && 
        $self->{asp}->Debug("bodyParameters : ".Dumper($bodyParameters)."\n");
    $asp->{dbg} && 
        $self->{asp}->Debug("bodyParameters keys : ".Dumper($bodyParameters->keys)."\n");
    for my $paramName($bodyParameters->keys){
        my @paramValues = $bodyParameters->get_all($paramName);
        $form{$paramName} = 1 <= $#paramValues ? [@paramValues]:$paramValues[0];
    }
    return (error => 0,processed => 1,form => \%form, upload => \%uploads);;
}

sub _ParseMultipart{
    my ($self,$asp)=@_;
	my $r = $asp->{r};
    ### undocumented feature of disabling file upload - keeping it.Evgeny
    if(!$self->_IsUploadEnabled($asp)) {
        return (error => 0,processed => 0,form => {}, upload => {});;
    }
    if($r->{PSGI}){
        $asp->{dbg} && $asp->Debug("using PSGI for upload ");
        return $self->_ParseMultipartPSGI($asp);
    }
    ### We are in none PSGI env
    my %upload ;

    if($asp->{file_upload_temp} = &config($asp, 'FileUploadTemp')) {
        eval "use CGI;";
    } else {
        # default leaves no temp files for prying eyes
        eval "use CGI qw(-private_tempfiles);";		
    }
    if($@) { 
        $self->{asp}->Error("can't use file upload without CGI.pm: $@");
        return (error => 1,processed => 0,form => {}, upload => {});;
    }
    
    # new behavior for file uploads when FileUploadMax is exceeded,
    # before it used to error abruptly, now it will simply skip the file 
    # upload data
    local $CGI::DISABLE_UPLOADS = $CGI::DISABLE_UPLOADS;
    if($asp->{file_upload_max} = &config($asp, 'FileUploadMax')) {
        if($self->{TotalBytes} > $asp->{file_upload_max} ) {
            $CGI::DISABLE_UPLOADS = 1;
        }
    }
    
    $asp->{dbg} && $asp->Debug("using CGI.pm version ".
                               (eval { CGI->VERSION } || $CGI::VERSION).
                               " for file upload support"
        );
    
    my %form;
    my $q;
    # $asp->{dbg} && $asp->Debug("ref r : ".(ref $self->{r}));
    $q = new CGI;
    $self->{cgi} = $q;
    $asp->Debug($q->param);
    for(my @names = $q->param) {
        my @params = $q->param($_);
        $form{$_} = @params > 1 ? [ @params ] : $params[0];
        if(ref($form{$_}) eq 'Fh' || ref($form{$_}) eq 'fh' || ref($form{$_}) eq 'CGI::File::Temp') {
            my $fh = $form{$_};
            binmode $fh if $asp->{win32};
            $upload{$_} = $q->uploadInfo($fh);
            if($asp->{file_upload_temp}) {
                $upload{$_}{TempFile} = $q->tmpFileName($fh);
                $upload{$_}{TempFile} =~ s|^/+|/|;
            }
            $upload{$_}{BrowserFile} = "$fh";
            $upload{$_}{FileHandle} = $fh;
            $upload{$_}{ContentType} = $upload{$_}{'Content-Type'};
            # tie the file upload reference to a collection... %upload
            # may be many file uploads note.
            $upload{$_} = bless $upload{$_}, 'Apache::ASP::Collection';
            $asp->{dbg} && $asp->Debug("file upload field processed for \$Request->{FileUpload}{$_}", $upload{$_});
        }
    }
    return (error => 0,processed => 1,form => \%form, upload => \%upload);;
}

sub DESTROY {
    my $self = shift;

    if($self->{cgi} && $self->{cgi}->can('DESTROY')) {
	# make sure CGI file handles are freed
	$self->{cgi}->DESTROY();
	$self->{cgi} = undef;
    }

    for(keys %{$self->{FileUpload}}) {
	my $upload = $self->{FileUpload}{$_};
	$self->{Form}{$_} = undef;
	if($upload->{FileHandle}) {
	    close $upload->{FileHandle};
	    # $self->{asp}->Debug("closing fh $upload->{FileHandle}");
	}
	$self->{FileUpload}{$_} = undef;
    }

    %$self = ();
}

# just returns itself
sub TIEHANDLE { $_[1] };

# just spill the cache into the scalar, so multiple reads are
# fine... whoever is reading from the cached contents must
# be reading the whole thing just once for this to work, 
# which is fine for CGI.pm
sub READ {
    my $self = $_[0];
    $_[1] ||= '';
    $_[1] .= $self->{content};
    $self->{ServerVariables}{CONTENT_LENGTH};
}

sub BINMODE { };

# COLLECTIONS, normal, Cookies are special, with the dictionary lookup
# directly aliased as this should be faster than autoloading
sub Form { shift->{Form}->Item(@_) }
sub FileUpload { shift->{FileUpload}->Item(@_) }
sub QueryString { shift->{QueryString}->Item(@_) }
sub ServerVariables { shift->{ServerVariables}->Item(@_) }

sub Params {
    my $self = shift; 
    $self->{Params}
      || die("\$Request->Params object does not exist, enable with 'PerlSetVar RequestParams 1'");
    $self->{Params}->Item(@_);
}

sub BinaryRead {
    my($self, $length) = @_;
    my $data;
	my $asp = $self->{asp};
	my $r = $asp->{r};
    return undef unless $self->{TotalBytes};
    if($self->{all_content_read}) {
        if($self->{TotalBytes}) {
            if(defined $length) {
                return substr($self->{content}, 0, $length);
            } else {
                return $self->{content}
            }
        } 
        return undef;
    } 
    defined($length) || ( $length = $self->{TotalBytes} );
    ### Under PSGI the STDIN is useless ,so we need to read the psgi.input
    if(ref $r eq 'Apache::ASP::PSGI'){
        $r->psgi_input()->read($data, $length, 0);
        return $data;
    };
    if(! $ENV{MOD_PERL}) {
        my $rv = sysread(*STDIN, $data, $length, 0);
        $asp->{dbg} && $asp->Debug("read $rv bytes from STDIN for CGI mode, tried $length bytes");
    } else {
        $r->read($data, $length);
        $asp->{dbg} && $asp->Debug("read ".length($data)." bytes, tried $length bytes");
    }
    return $data;
}

sub Cookies {
    my($self, $name, $key) = @_;

    if(! $name) {
	$self->{Cookies};
    } elsif($key) {
	$self->{Cookies}{$name}{$key};
    } else {
	# when we just have the name, are we expecting a dictionary or not
	my $cookie = $self->{Cookies}{$name};
	if(ref $cookie && wantarray) {
	    return %$cookie;
	} else {
	    # CollectionItem support here one day, to not return
	    # an undef object, CollectionItem needs tied hash support
	    return $cookie;
	}
    }
}

sub ParseParams {
    my($self, $string) = @_;
    ($string = $$string) if ref($string); ## faster if we pass a ref for a big string

    my %params;
    defined($string) || return(\%params);
    my @params = split /[\&\;]/, $string, -1;

    # we have to iterate through the params here to collect multiple values for 
    # the same param, say from a multiple select statement
    for my $pair (@params) {
	my($key, $value) = map { 
	    # inline for greater efficiency
	    # &Unescape($self, $_) 
	    my $todecode = $_;
	    $todecode =~ tr/+/ /;       # pluses become spaces
	    $todecode =~ s/%([0-9a-fA-F]{2})/chr(hex($1))/ge;
	    $todecode;
	} split (/\=/, $pair, 2);
	if(defined $params{$key}) {
	    my $collect = $params{$key};

	    if(ref $collect) {
		# we have already collected more than one param for that key
		push(@{$collect}, $value);
	    } else {
		# this is the second value for a key we've seen, start array
		$params{$key} = [$collect, $value];
	    }
	} else {
	    # normal use, one to one key value pairs, just set
	    $params{$key} = $value;
	}
    }

    \%params;
}

# unescape URL-encoded data
sub Unescape {
    my $todecode = $_[1];
    $todecode =~ tr/+/ /;       # pluses become spaces
    $todecode =~ s/%([0-9a-fA-F]{2})/chr(hex($1))/ge;
    $todecode;
}

*config = *Apache::ASP::config;

1;
