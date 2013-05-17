package JavaScript::Shell;
use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use File::Spec;
use Carp;
use JSON::Any;
use Data::Dumper;
use IPC::Open2;

our $VERSION = '0.01';

#===============================================================================
# Global Methods
#===============================================================================
my $MethodsCounter = 0;
my $METHODS = {
    ##pre defined methods
    __stopLoop => \&stop
};

#===============================================================================
# Registered Methods
#===============================================================================
sub stop {
    my $self = shift;
    my $args = shift;
    $self->{_return_value} = $args;
    $self->{running} = 0;
}

sub new {
    my $class = shift;
    my $opt = shift;
    
    if ($opt->{onError} && ref $opt->{onError} ne 'CODE'){
        croak "onError options accepts a code ref only";
    } else {
        $opt->{onError} = sub {
            my $js = shift;
            my $error = shift;
            #$js->destroy();
            
            print STDERR $error->{type}
            . ' : '
            . $error->{message}
            . ' at '
            . $error->{file}
            . ' line ' . $error->{line} . "\n";
            exit(0);
        }
    }
    
    ( my $path = $INC{'JavaScript/Shell.pm'} ) =~ s/\.pm$//;
    my $self = bless({
        running => 0,
        _path => $path,
        _json => JSON::Any->new,
        _ErrorHandle => $opt->{onError},
        pid => $$
    },$class);
    
    $self->_run();
    return $self;
}


#===============================================================================
# createContext
#===============================================================================
sub createContext {
    my $self = shift;
    my $sandbox = shift;
    
    if (defined $sandbox && ref $sandbox ne 'HASH'){
        croak "createContext accepts HASH Ref Only";
    }
    
    return JavaScript::Shell::Context->new($self,$sandbox);
}

#===============================================================================
# helpers
#===============================================================================
sub path        {   shift->{_path}                  }
sub json        {   shift->{_json}                  }
sub toJson      {   shift->{_json}->objToJson(@_)   }
sub toObject    {   shift->{_json}->jsonToObj(@_)   }
sub context     {   shift->{context}                }
sub watcher     {   shift->{FROM_JSHELL}            }

#===============================================================================
# Running Loop
#===============================================================================
sub isRunning { shift->{running} == 1 }
sub run {
    
    my $self = shift;
    my $once = shift;
    
    return if $self->isRunning;
    $self->{running} = 1;
    
    if ($once){
        $self->call('jshell.endLoop');
    }
    
    my $WATCHER = $self->watcher;
    my $catch;
    
    while($catch = <$WATCHER>){
        $catch =~ s/^.*js> //;
        if ($catch =~ s/to_perl\[(.*)\]end_perl/$1/){
            $self->processData($catch);
        } else {
            #if (!$once) {
                STDOUT->print($catch);
            #}
        }
        
        last if !$self->isRunning;
    }
    
    return $self->{_return_value};
}

sub run_once {
    my $self = shift;
    my $ret = $self->run(1);
    return $ret;
}

#===============================================================================
# IPC - listen
#===============================================================================
sub _run {
    my $self = shift;
    my $file = shift;
    
    my @cmd = ('E:/spider/js.exe','-i','-e', $self->_ini_script());
    my $pid = open2($self->{FROM_JSHELL},$self->{TO_JSHELL}, @cmd);
    $self->{jshell_pid} = $pid;
    
    $SIG{INT} = sub {
        #$self->eval(qq!
        #    quit();
        #!);
        #
        kill -9,$pid;
        ###restore INT signal
        #$SIG{INT} = 'DEFAULT';
        
        print "^C\n";
        exit(0);
    };
    
    ## set error handler
    $self->Set('jshell.onError' => sub {
        my $js = shift;
        my $args = shift;
        $self->{_ErrorHandle}->($js,$args->[0]);
    });
    
    return $self;
}

#===============================================================================
# handle errors
#===============================================================================
sub onError {
    my $self = shift;
    my $handle = shift;
    
    if (ref $handle ne 'CODE'){
        croak "onError method requires a code ref";
    }
    
    $self->{_ErrorHandle} = $handle;
    return $self;
}


#===============================================================================
# send code to shell
#===============================================================================
sub send {
    my $self = shift;
    my $code = shift;
    $self->{TO_JSHELL}->print($code . "\n");
}

#===============================================================================
# set variable/object/function
#===============================================================================
sub Set {
    my $self = shift;
    my $name = shift;
    my $value = shift;
    
    my $ref = ref $value;
    if ($ref eq 'CODE'){
        $MethodsCounter++;
        $METHODS->{$MethodsCounter} = $value;
        $self->call('jshell.setFunction',$name,$MethodsCounter,$self->{context});
        #print Dumper "$MethodsCounter = $name";
    } else {
        $self->call('jshell.Set',$name,$value,$self->{context});
    }
    
    return $self;
}

#===============================================================================
# get values
#===============================================================================
sub get {
    my $self = shift;
    my $value = shift;
    
    my $val = JavaScript::Shell::Result->new();
    
    $METHODS->{setValue} = sub {
        my $self = shift;
        my $args = shift;
        $val->add($args);
        return 1;
    };
    
    #$self->{running} = 1;
    $self->call('jshell.getValue',$value,$self->{context},@_);
    $self->run_once();
    return $val;
}


#==============================================================================
# Call Javascript Function
#==============================================================================
sub call {
    my $self = shift;
    my $fun = shift;
    my $args = \@_;
    
    my $send = {
        fn => $fun,
        args => $args,
        context => $self->{context}
    };
    
    $send = $self->toJson($send);
    $self->send('jshell.execFunc(' . $send . ')');
    $self->run_once();
}

#==============================================================================
# eval Script string
#==============================================================================
sub load {
    my $self = shift;
    my $file = shift;
    
    $file = File::Spec->canonpath( $file ) ;
    $file =~ s/\\/\\\\/g;
    $self->call('load' => $file);
    
    #open (my $fh,'<', $file) or croak $!;
    #local $/;
    #my $lines = <$fh>;
    #print Dumper $lines;
    #$self->eval($lines);
}

sub eval {
    my $self = shift;
    my $code = shift;
    $self->call('jshell.evalCode',$code,$self->{context});
    
}

#===============================================================================
#  Process data from & to js shell
#===============================================================================
sub processData {
    my $self = shift;
    my $obj = shift;
    
    #convert recieved data from json to perl hash
    #then translate and process
    my $hash = $self->toObject($obj);
    my $args = '';
    
    my $callMethod;
    if (my $method = $hash->{method}){
        if (my $sub = $METHODS->{$method}) {
            $callMethod = sub { $self->$sub(shift,shift) };
        } else {
            croak "can't locate method $method";
        }
        
        $args = $callMethod->($hash->{args},$hash);
    }
    
    $hash->{_args} = $args;
    $self->jclose($hash);
    
}

sub jclose {
    my $self = shift;
    my $args = shift;
    $args = $self->toJson($args);
    return $self->send("jshell.setArgs($args)");
}

#===============================================================================
# script to start the shell, loading some required system js files
#===============================================================================
sub _ini_script {
    my $self = shift;
    my $file = shift;
    my $path = $self->{_path} || '';
    
    my $builtin = "$path/builtin.js";
    $builtin = File::Spec->canonpath( $builtin ) ;
    
    ##-- Fix -- spidermonkey shell complain about
    ## malformed hexadecimal character escape sequence
    $builtin =~ s/\\/\\\\/g;
    
    my @script = (
        '"',
        "load('$builtin')",
        '"'
    );
    
    my $javascript = join "",@script;
    return $javascript;
}


#===============================================================================
# TODO : error handling, I'm not familiar with piping
#===============================================================================

sub destroy {
    my $self = shift;
    eval {
        $self->eval(qq{
            quit();
        });
    };
}

sub DESTROY {
    my $self = shift;
    $self->destroy();
}

#===============================================================================
# JavaScript::Shell::Result
#===============================================================================
package JavaScript::Shell::Result;

sub new {
    my $class = shift;
    return bless([],$class);
}

sub add {
    my $self = shift;
    my $values = shift;
    $self->[0] = $values;
}

sub value {
    my $self = shift;
    my $i = shift;
    return $i ? $self->[0]->[$i] : $self->[0];
}

#===============================================================================
# JavaScript::Shell::Context
#===============================================================================
package JavaScript::Shell::Context;
use base 'JavaScript::Shell';
no warnings 'redefine';
my $CONTEXT = 0;

sub new {
    my $class = shift;
    my $js = shift;
    my $sandbox = shift;
    $CONTEXT++;
    
    $js->call('jshell.setContext',$CONTEXT,$sandbox);
    
    my $args = {};
    
    %{$args} = %{$js};
    my $self = bless($args,$class);
    $self->{context} = $CONTEXT;
    return $self;
}


#===============================================================================
# JavaScript::Shell::Template
# XXXX - ToDo
#===============================================================================
#package JavaScript::Shell::Template;
#use base 'JavaScript::Shell';
#no warnings 'redefine';
#
#sub new {
#    my $class = shift;
#    my $js = shift;
#    my $name = shift;
#    
#    my $args = {};
#    
#    %{$args} = %{$js};
#    my $self = bless($args,$class);
#    
#    return $self;
#}

1;

=pod

=head1 NAME

JavaScript::Shell - Run Spidermonkey shell from Perl

=head1 SYNOPSIS

    use JavaScript::Shell;
    use strict;
    use warnings;
    
    my $js = JavaScript::Shell->new();
    
    ##create context
    my $ctx = $js->createContext();
    
    $ctx->Set('str' => 'Hello');
    
    $ctx->Set('getName' => sub {
        my $context = shift;
        my $args    = shift;
        my $firstname = $args->[0];
        my $lastname  = $args->[1];
        return $firstname . ' ' . $lastname;
    });
    
    $ctx->eval(qq!
        function message (){
            var name = getName.apply(this,arguments);
            var welcome_message = str;
            return welcome_message + ' ' + name;
        }
    !);
    
    
    my $val = $ctx->get('message' => 'Mamod', 'Mehyar')->value;
    
    print $val . "\n"; ## prints 'Hello Mamod Mehyar'
    
    $js->destroy();

=head1 DESCRIPTION

JavaScript::Shell will turn Spidermonkey shell to an interactive environment
by connecting it to perl

It will allow you to bind functions from perl and call them from javascript or
create functions in javascript and call them from perl

=head1 WHY

While I was working on a project where I needed to connect perl with javascript
I had a lot of problems with existing javascript modules, they were eaither hard
to compile or out of date, and since I don't know C/C++ - creating my own
perl / javascript binding wasn't an option, so I thought of this approach as an
alternative.

Even though this sounds crazy to do, to my surprise it worked as expected - at
least in my usgae cases

=head1 SPEED

JavaScript::Shell connect spidermonkey with perl through IPC bridge using
L<IPC::Open2> so execution speed will never be as fast as using C/C++
bindings ported to perl directly

There is another over head when translating data types to/from perl, since it
converts perl data to JSON & javascript JSON to perl data back again.

Saying that the over all speed is acceptable and you can take some steps to
improve speed like

=over 4

=item L<JSON::XS>

Make sure you have L<JSON::XS> installed - this is important, JavaScript::Shell
uses JSON::Any to parse data and it will use any available JSON parser
but if you have JSON::XS installed in your system it will use it by default as
it's the fastest JSON parser available

=item Data Transfer

Try to transfer small data chunks between processes when possible, sending
large data will be very slow

=item Minimize calls

Minimize number of calls to both ends, let each part do it's processing
for eaxmple:

    ##instead of
    
    $js->eval(qq!
        function East (){}
        function West (){}
        function North (){}
        function South (){}
    !);
    
    $js->call('East');
    $js->call('West');
    $js->call('North');
    $js->call('South');
    
    ##do this
    
    $js->eval(qq!
        function all () {
            
            East();
            West();
            North();
            South();
            
        }
        
        function East (){}
        function west (){}
        function North (){}
        function South (){}
        
    !);
    
    $js->call('all');

=back


=head1 CONTEXT

Once you intiate JavaScript::Shell you can create as many contexts
as you want, each context will has it's own scope and will not overlap
with other created contexts.

    my $js = JavaScript::Shell->new();
    my $ctx = $js->createContext();

You can pass a hash ref with simple data to C<createContext> method as a
sandbox object and will be copied to the context immediately

    my $ctx->createContext({
        Foo => 'Bar',
        Foo2 => 'Bar2'
    });

=head1 FUNCTIONS

=head2 new

Initiates SpiderMonkey Shell

=head2 createContext

creates a new context

=head2 run

This will run javascript code in a blocking loop until you call jshell.endLoop()
from your javascript code

    $js->Set('Name' => 'XXX');
    $js->eval(qq!
        for (var i = 0; i < 100; i++){
            
        }
        
        jshell.endLoop();
        
    !);
    
    $js->run();
    
    ##will never reach this point unless we call
    ## jshell.endLoop(); in javascript code as above
    

=head2 Set

Sets/Defines javascript variables, objects and functions from perl
    
    ## set variable 'str' with Hello vales
    $ctx->Set('str' => 'Hello');
    
    ## set 'arr' Array Object [1,2,3,4]
    $ctx->Set('arr' => [1,2,3,4]);
    
    ## set Associated Array Object
    $ctx->Set('obj' => {
        str1 => 'something',
        str2 => 'something ..'
    });
    
    ## set 'test' function
    ## caller will pass 2 arguments
    ## 1- context object
    ## 2- array ref of all passed arguments
    $ctx->Set('test' => sub {
        my $context = shift;
        my $args = shift;
        
        return $args->[0] . ' ' . $args->[1];
    });
    
    ## javascript object creation style
    
    $ctx->Set('obj' => {});
    
    #then
    $ctx->Set('obj.name' => 'XXX');
    $ctx->Set('obj.get' => sub { });
    ...

=head2 get

get values from javascript code, returns a C<JavaScript::Shell::Value> Object
    
    my $ret = $ctx->get('str');
    print $ret->value; ## Hello
    
    ## remember to call value to get the returned string/object
    
get method will search your context for a matched variable/object/function and
return it's value, if the name was detected for a function in will run this
function first and then returns it's return value
    
    $ctx->get('obj.name')->value; ## XXX
    
    ##you can pass variables when trying to get a function
    $ctx->get('test' => 'Hi','Bye')->value; ## Hi Bye
    
    ##get an evaled script values
    
    $ctx->get('eval' => qq!
        var n = 2;
        var x = 3;
        n+x;
    !)->value;  #--> 5
    
    
=head2 call

Calling javascript functions from perl, same as C<get> but doesn't return any
value

    $ctx->call('test');

=head2 eval

eval javascript code

    $ctx->eval(qq!
        
        //javascript code
        var n = 10;
        for(var i = 0; i<100; i++){
            n += 10;
        }
        ...
    !);
    
=head2 onError

set error handler method, this method accepts a code ref only. When an error
raised from javascript this code ref will be called with 2 arguments

=over 4

=item * JavaScript::Shell instance

=item * error object - Hash ref

=back

Error Hash has the folloing keys

=over 4

=item * B<message>  I<error message>

=item * B<type>     I<javascript error type: Error, TypeError, ReferenceError ..>

=item * B<file>     I<file name wich raised this error>

=item * B<line>     I<line number>

=item * B<stack>    I<string of the full stack trace>

=back

Setting error hnadler example

    my $js = JavaScript::Shell->new();
    $js->onError(sub{
        my $self = shift;
        my $error = shift;
        print STDERR $error->{message} . ' at ' . $error->{line}
        exit(0);
    });

=head2 destroy

Destroy javascript shell / clear context

    my $js = JavaScript::Shell->new();
    my $ctx->createContext();
    
    ##clear context;
    $ctx->destroy();
    
    ##close spidermonkey shell
    $js->destroy();

=head1 LICENSE



=head1 COPYRIGHTS



=cut


