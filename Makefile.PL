use 5.016002;
use ExtUtils::MakeMaker;
use FindBin qw($Bin $RealBin);
use Archive::Extract;
use Data::Dumper;

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
My_WriteMakefile(
    NAME => 'JavaScript::Shell',
    VERSION_FROM => 'lib/JavaScript/Shell.pm', # finds $VERSION
    #EXE_FILES => ['bin/spidermonkey.exe','bin/nss3.dll','bin/msvcr100.dll','bin/mozglue.dll'],
    PREREQ_PM => {
	'JSON::Any' => 0
    },
    ($] >= 5.005 ? ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM => 'lib/JavaScript/Shell.pm', # retrieve abstract from module
       AUTHOR => 'Mamod A. Mehyar <mamod.mehyar@gmail.com>') : ())
);

sub My_WriteMakefile {
    my %params=@_;
    my $ok = getBinaries();
    WriteMakefile(%params);
    #print Dumper $Bin;
    
}



sub getBinaries {
    
    my $os = $^O;
    my $file;
    my $plat;
    if ($os =~ /^MS/i){
	$file = 'jsshell-win32.zip';
	$plat = 'win';
    } elsif ($os =~ /^Mac/i){
	$file = 'jsshell-mac.zip';
	$plat = 'mac';
    } else {
	$file = 'jsshell-linux-i686.zip';
	$plat = 'linux';
    }
    
    
    my $response;
    my $stream;
    my $url = 'http://ftp.mozilla.org/pub/mozilla.org/firefox/nightly/latest-trunk/' . $file;
    #my $url = 'http://127.0.0.1/' . $file;
    #trying curl
    print "\n ==================== Trying curl ============================= \n";
    system "curl $url";
    
    ##trying wget
    if (!-e $file) {
	print "\n ===================== Trying wget ==========================\n";
	system "wget $url";
    }
    
    if (!-e $file) {
	
	print "\n ========== Trying to fetch using LWP::UserAgent ==========\n";
	eval "use LWP::UserAgent";
	if ($@){
	    print "We couldn't locate LWP::UserAgent Module\n";
	    print "LWP::UserAgent required to fetch regexes.yaml from server\n";
	    print "Please install it or get regexes.yaml file manually from\n";
	    print "https://raw.github.com/tobie/ua-parser/master/regexes.yaml\n";
	    print "and place it in the root folder of this distro\n";
	    print "then run Makefile.PL again\n";
	    exit;
	}
	
	open(my $fh,'>>',$file);
	binmode($fh);
	
	my $ua = LWP::UserAgent->new;
	$ua->timeout(5);
	$ua->env_proxy();
	$response = $ua->get($url);
	if ($response->is_success) {
	    $fh->print($response->content);
	} else {
	    
	    return 0;
	}
    }
    
    eval {
	my $ae = Archive::Extract->new( archive => $file );
	my $ok = $ae->extract( to => './lib/JavaScript/Shell/bin' );
    };
    
    if ($@){
	return 0;
    }
    
    ##remove
    unlink($file);
    
    ##rename js to spidermonkey[.exe];
#    if ($plat eq 'win'){
#	rename './bin/js.exe','./bin/spidermonkey.exe'
#    } elsif ($plat eq 'linux'){
#	rename './lib/bin/js','./bin/spidermonkey'
#    } else {
#	
#    }
    
    return 1;
    
}


