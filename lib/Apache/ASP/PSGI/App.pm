package Apache::ASP::PSGI::App;
use strict;
use Plack::Handler::Apache2;
use Apache::ASP;
use Apache::ASP::PSGI;
use File::Basename;
use File::Spec;
use Data::Dumper;
use YAML::XS qw(LoadFile);
use Plack::Middleware::Static;
use Cwd qw(abs_path);


our $DEFAULT_CONFIG_FILE = 'config.yml';
our $DEFAULT_ASP_FILES_REGEXP = qr{.*\.asp$};

=head
    Get an PSGI Application
    @param $config - a hash reference for application configuration (what you
                     normally put into apache config file.
    Existing configuration parameters (except the once defined by Apache::ASP
    itself). 

    ConfigFile - The name of configuration file of the application, it should
    defined relatively to the path of the application itself.Most likely you
    would just put the file in the same directory as the app psgi startup script
    itself. If the file does not exists you will get a warning . The default if
    not set is config.yml.

    ReloadConfig - Reload the conf file every time the app gets request. Default
    to 0 .
=cut

sub get_app {
    my ($config) = @_;
    ### 1. we should know what file are we looking for
    ### 2. how do we lookup the configuration & .asa files ?
    my  ($package, $caller_script, $line) = caller();
    my $working_dir = _get_working_directory($caller_script,$config);
    ### Now that we have the app directory, look for config file. If the
    ### configuration is set to reload the file, then we will do so in app sub.
    my $readConfig = _read_config_file($working_dir,$config);
    if($readConfig){
        $config = $readConfig;
    }
    if(!exists $config->{Global}){
        $config->{Global} = $working_dir;
    }
    # my $oMidStatic = Plack::Middleware::Static->new(root => $working_dir);
    my $app = sub {
        my ($env) = @_;
        ### Analyze the PATH_INFO to find the requested .asp file 
        if($config->{ReloadConfig}){
            my $readConfig = _read_config_file($working_dir,$config);
            if($readConfig){
                $config = $readConfig;
            }
        }
        my $filename = _discover_script_file($working_dir,$env,$config);
        if(!$filename){
            return [404,[],[]];
        }
        if(! -r $filename){
            return [404,[],[]];
        }
        # if($filename !~ $DEFAULT_ASP_FILES_REGEXP){
        #     return $oMidStatic->call($env);
        # }
        my $errors = $env->{'psgi.errors'};
        my %custom_env = (config => $config,%$env);
        if($config->{debug_psgi}){
            $errors->print("ENV   : ".Dumper(%custom_env));
        }
        my $h = Apache::ASP::PSGI->init($filename, \%custom_env, $config);
        &Apache::ASP::handler($h);
        my $status = $h->status();
        if($config->{debug_psgi}){
            $errors->print("STATUS   : ".$status);
            $errors->print("GOT STATUS   : ".$h->status());
            # $errors->print("h   : ".Dumper($h));
        }
        $status = $status || 200;
        #$c++;
        ### TODO: the output in case of error should depend on the log level of
        ### asp app. Sometime the errors should be printed on the screen
        if($status == 500){
            if($config->{debug_psgi}){
                $errors->print("Error 500");
                $errors->print("status   : ".$status);
                $errors->print("headers   : ".Dumper($h->headers_to_array()));
                # $errors->print("h   : ".Dumper($h));
            }
            ### TODO: how to print debug info of asp if there was an error?
            # if($config->{Debug}){
            #     return [500,[$h->{debugs_output}],[]];
            # }
            return [500,[],['Internal Server Error']];
        }
        my @headers = $h->headers_to_array();
        my @psgiHeaders;
        ### Remove the status header that the asp sets or the Plack will fail.
        for (my $i=0;$i <= $#headers;$i+=2){
            my $headerName = $headers[$i];
            if($headerName !~ /^status$/i){
                push @psgiHeaders,$headers[$i],$headers[$i+1];
            }
        }
        if($config->{debug_psgi}){
            $errors->print("status   : ".$status);
            $errors->print("headers  : ".Dumper(@psgiHeaders));
        }
        return [
            $status,
            \@psgiHeaders,
            [ $h->{out} ],
            ];
    };
    ### wrap the app with static middleware such that all none .asp files would
    ### be servered as a static once by plack.
    my $is_asp_file_sub = sub {
        my ($path_info,$env) = @_;
        if($path_info !~ $DEFAULT_ASP_FILES_REGEXP){
            return 1;
        }
        return 0;
    };
    $app = Plack::Middleware::Static->wrap(
        $app,
        root => $working_dir,
        path => $is_asp_file_sub);
    if($config->{BehindProxy}){
        if(exists $config->{Trust}){
            $app = Plack::Middleware::XForwardedFor->wrap(
                $app,
                $config->{Trust});
        }else{
            $app = Plack::Middleware::XForwardedFor->wrap(
                $app,
                qw(127.0.0.1/8));
        }
    }
    return $app;
}

sub _read_config_file{
    my ($working_dir,$config,$error_handler)=@_;
    my $configFileName = $DEFAULT_CONFIG_FILE;
    if($config->{ConfigFile}){
        $configFileName = $config->{ConfigFile};
    }
    $configFileName = File::Spec->catfile('', $working_dir, $configFileName );
    if(-r $configFileName){
        my $configFromFile = LoadFile($configFileName);
        if($error_handler){
            $error_handler->print("Warning : ".
                                  "Failing read of config file ($configFileName)\n");
        }
        $config = {%$config,%$configFromFile};
        return $config;
    }else{
        if($error_handler){
            $error_handler->print("Warning : ".
                                  "There is no configuration file found ($configFileName)\n");
        }
    }
    return undef;
}

sub _get_working_directory{
    my ($caller_script,$config) = @_;
    if($config->{APP_DIR}){
        my $cdirname = File::Spec->canonpath( $config->{APP_DIR} ) ;
        return $cdirname;
    }
    my ($app_filename, $app_dirs, $app_suffix) = fileparse($caller_script);
    $app_dirs = File::Spec->canonpath( $app_dirs ) ;
    return $app_dirs;
}

sub _discover_script_file{
    my ($app_dir,$env,$config) = @_;
    my $uri = $env->{PATH_INFO};
    my $errors = $env->{'psgi.errors'};
    ### Now that we have the app dir, try to find the target file
    $uri =~ m|(\/.*)\?*|i;
    my $filename = $1;
    if($config->{debug_psgi}){
        # $errors->print("caller_script : $caller_script\n");
        $errors->print("app_dirs : $app_dir\n");
        $errors->print("filename : $filename\n");
        $errors->print("uri : $uri\n");
    }
    # $filename = File::Spec->catfile('', $app_dir, $filename );
    my $cfilename = File::Spec->catfile('', $app_dir, $filename );
    $cfilename = File::Spec->canonpath( $cfilename ) ;
    ### Can we find the absolute path to the file?
    if($config->{debug_psgi}){
        $errors->print("cfilename : $cfilename\n");
    }
    my $abs_file_path = abs_path($cfilename);
    my $abs_dir_path = abs_path($app_dir);
    ### check if the file is inside the app directory 
    
    if(index($abs_file_path,$abs_dir_path) < 0){
        return "";
    }
    return $abs_file_path;
}

1;
