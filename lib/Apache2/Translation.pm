package Apache2::Translation;

use 5.008;
use strict;
use warnings;
no warnings qw(uninitialized);

use Apache2::RequestRec;
use Apache2::RequestUtil;
use Apache2::RequestIO;
use Apache2::ServerRec;
use Apache2::ServerUtil;
use Apache2::Connection;
use Apache2::CmdParms;
use Apache2::Directive;
use Apache2::Module;
use Apache2::Log;
use Apache2::ModSSL;
use APR::Table;
use APR::SockAddr;
use attributes;
use Apache2::Const -compile=>qw{:common :http
				:conn_keepalive
				:methods
				:override
				:satisfy
				:types
				:proxy
				:options
				ITERATE TAKE1 RAW_ARGS RSRC_CONF};

use Perl::AtEndOfScope;
use YAML ();

our $VERSION = '0.16';

our ($cf,$r,$ctx);
sub undef_cf_r_ctx {undef $_ for ($cf,$r,$ctx);}

our ($URI, $REAL_URI, $METHOD, $QUERY_STRING, $FILENAME, $DOCROOT,
     $HOSTNAME, $PATH_INFO, $HEADERS, $REQUEST,
     $C, $CLIENTIP, $KEEPALIVE,
     $MATCHED_URI, $MATCHED_PATH_INFO, $DEBUG, $STATE, $KEY, $RC);

BEGIN {
  package Apache2::Translation::Error;

  use strict;

  sub new {
    my $class=shift;
    bless {@_}=>$class;
  }
}

BEGIN {
  package Apache2::Translation::_ctx;

  use strict;

  sub TIESCALAR {
    my $class=shift;
    bless {@_}=>$class;
  }

  sub STORE {
    my $I=shift;
    $ctx->{$I->{member}}=shift;
  }

  sub FETCH {
    my $I=shift;
    return $ctx->{$I->{member}};
  }
}

BEGIN {
  package Apache2::Translation::_notes;

  use strict;

  sub TIESCALAR {
    my $class=shift;
    bless {@_}=>$class;
  }

  sub STORE {
    my $I=shift;
    $r->notes->{__PACKAGE__."::".$I->{member}}=shift;
  }

  sub FETCH {
    my $I=shift;
    return $r->notes->{__PACKAGE__."::".$I->{member}};
  }
}

BEGIN {
  package Apache2::Translation::_r;

  use strict;

  sub TIESCALAR {
    my $class=shift;
    my %o=@_;
    bless eval("sub {\$r->$o{member}(\@_)}")=>$class;
  }

  sub STORE {my $I=shift; $I->(@_);}
  sub FETCH {my $I=shift; $I->();}
}

tie $URI, 'Apache2::Translation::_r', member=>'uri';
tie $REAL_URI, 'Apache2::Translation::_r', member=>'unparsed_uri';
tie $METHOD, 'Apache2::Translation::_r', member=>'method';
tie $QUERY_STRING, 'Apache2::Translation::_r', member=>'args';
tie $FILENAME, 'Apache2::Translation::_r', member=>'filename';
tie $DOCROOT, 'Apache2::Translation::_r', member=>'document_root';
tie $HOSTNAME, 'Apache2::Translation::_r', member=>'hostname';
tie $PATH_INFO, 'Apache2::Translation::_r', member=>'path_info';
tie $REQUEST, 'Apache2::Translation::_r', member=>'the_request';
tie $HEADERS, 'Apache2::Translation::_r', member=>'headers_in';

tie $C, 'Apache2::Translation::_r', member=>'connection';
tie $CLIENTIP, 'Apache2::Translation::_r', member=>'connection->remote_ip';
tie $KEEPALIVE, 'Apache2::Translation::_r', member=>'connection->keepalive';

tie $MATCHED_URI, 'Apache2::Translation::_ctx', member=>' uri';
tie $MATCHED_PATH_INFO, 'Apache2::Translation::_ctx', member=>' pathinfo';
tie $STATE, 'Apache2::Translation::_ctx', member=>' state';
tie $KEY, 'Apache2::Translation::_ctx', member=>' key';
tie $RC, 'Apache2::Translation::_ctx', member=>' rc';

tie $DEBUG, 'Apache2::Translation::_notes', member=>' debug';


use constant {
  START=>0,
  PREPROC=>1,
  PROC=>2,
  LAST_ROUND=>3,
  DONE=>4,

  PRE_URI=>':PRE:',
};

my %states=
  (
   start=>START,
   preproc=>PREPROC,
   proc=>PROC,
   done=>DONE,
  );

my @state_names=
  (
   'start',
   'preproc',
   'proc',
   'last round',
   'done',
  );

my %default_shift=
  (
   &START   => &PREPROC,
   &PREPROC => &PROC,
   &PROC    => &PROC,
  );

my %next_state=
  (
   &START   => &PREPROC,
   &PREPROC => &PROC,
   &PROC    => &DONE,
  );

my @directives=
  (
   {
    name         => 'TranslationProvider',
    req_override => Apache2::Const::RSRC_CONF,
    args_how     => Apache2::Const::ITERATE,
    errmsg       => 'TranslationProvider Perl::Class [param1 ...]',
   },
   {
    name         => '<TranslationProvider',
    func         => __PACKAGE__.'::TranslationContainer',
    req_override => Apache2::Const::RSRC_CONF,
    args_how     => Apache2::Const::RAW_ARGS,
    errmsg       => <<'EOF',
<TranslationProvider Perl::Class>
    Param1 Value1
    Param2 Value2
    ...
</TranslationProvider>
EOF
   },
   {
    name         => 'TranslationKey',
    req_override => Apache2::Const::RSRC_CONF,
    args_how     => Apache2::Const::TAKE1,
    errmsg       => 'TranslationKey string',
   },
   {
    name         => 'TranslationEvalCache',
    req_override => Apache2::Const::RSRC_CONF,
    args_how     => Apache2::Const::TAKE1,
    errmsg       => 'TranslationEvalCache how_many',
   },
  );
Apache2::Module::add(__PACKAGE__, \@directives);

sub postconfig {
  my($conf_pool, $log_pool, $temp_pool, $s) = @_;

  for(; $s; $s=$s->next ) {
    my $cfg=Apache2::Module::get_config( __PACKAGE__, $s );
    if( $cfg ) {
      if( ref($cfg->{provider_param}) eq 'ARRAY' and
	  !defined $cfg->{provider} ) {
	my $param=$cfg->{provider_param};
	my $class=$param->[0];
	eval "use Apache2::Translation::$class;";
	if( $@ ) {
	  warn "ERROR: Cannot use Apache2::Translation::$class: $@" if $@;
	  eval "use $class;";
	  die "ERROR: Cannot use $class: $@" if $@;
	} else {
	  $class='Apache2::Translation::'.$class;
	}
	$cfg->{provider}=$class->new( @{$param}[1..$#{$param}] );
      }
    }
  }

  return Apache2::Const::OK;
}

sub setPostConfigHandler {
  my $h=Apache2::ServerUtil->server->get_handlers('PerlPostConfigHandler')||[];
  unless( grep $_==\&postconfig, @{$h} ) {
    Apache2::ServerUtil->server->push_handlers
	('PerlPostConfigHandler'=>\&postconfig);
  }
}

sub TranslationProvider {
  my($I, $parms, @args)=@_;
  $I=Apache2::Module::get_config(__PACKAGE__, $parms->server);
  unless( $I->{provider_param} ) {
    $I->{provider_param}=[shift @args];
  }
  push @{$I->{provider_param}}, map {
    my @x=split /=/, $_, 2;
    (lc( $x[0] ), $x[1]);
  } @args;
  setPostConfigHandler;
}

sub TranslationContainer {
  my($I, $parms, $rest)=@_;
  $I=Apache2::Module::get_config(__PACKAGE__, $parms->server);
  local $_;
  my @l=map {
    s/^\s*//;
    s/\s*$//;
    if( length($_) ) {
      my @x=split( /\s+/, $_, 2 );
      $x[0]=lc $x[0];
      $x[1]=~s/^(["'])(.*)\1$/$2/;
      @x;
    } else {
      ();
    }
  } split /\n/, $parms->directive->as_string;
  $I->{provider_param}=[$rest=~/([\w:]+)/, @l];
  setPostConfigHandler;
}

sub TranslationKey {
  my($I, $parms, $arg)=@_;
  $I=Apache2::Module::get_config(__PACKAGE__, $parms->server);
  $I->{key}=$arg;
}

sub TranslationEvalCache {
  my($I, $parms, $arg)=@_;
  $I=Apache2::Module::get_config(__PACKAGE__, $parms->server);

  if( $arg!~/^\d/ ) {
    if( tied(%{$I->{eval_cache}}) ) {
      untie(%{$I->{eval_cache}});
    }
  } else {
    my $o;
    if( $o=tied(%{$I->{eval_cache}}) ) {
      $o->max_size($arg);
    } else {
      eval "use Tie::Cache::LRU";
      die "$@" if $@;
      tie %{$I->{eval_cache}}, 'Tie::Cache::LRU', $arg;
    }
  }
}

# There is no need for a special SERVER_MERGE. By default a VirtualHost
# uses only its very own configuration. Nothing is inherited from the
# base server.
#sub SERVER_MERGE {}

sub SERVER_CREATE {
  my ($class, $parms)=@_;

  return bless {
		key=>'default',
		eval_cache=>{},
	       } => $class;
}

################################################################
# here begins the real stuff
################################################################

sub handle_eval {
  my ($eval)=@_;

  my $sub=$cf->{eval_cache}->{$eval};

  unless( $sub ) {
    $sub=<<"SUB";
sub {
  return do {
    $eval
  };
}
SUB

    $sub=eval $sub;
    if( $@ ) {
      (my $e=$@)=~s/\s*\Z//;
      $r->warn( __PACKAGE__.": $eval: $e" );
      return;
    }
    $cf->{eval_cache}->{$eval}=$sub;
  }

  my @rc;
  if( wantarray ) {
    @rc=eval {$sub->();};
  } else {
    $rc[0]=eval {$sub->();};
  }
  die $@ if( ref $@ );
  if( $@ ) {
    (my $e=$@)=~s/\s*\Z//;
    $r->warn( __PACKAGE__.": $eval: $e" );
  }

  return wantarray ? @rc : $rc[0];
}

sub add_note {
  $r->notes->add(__PACKAGE__."::".$_[0], $_[1]);
}

my %action_dispatcher;
%action_dispatcher=
  (
   do=>sub {
     my ($action, $what)=@_;
     handle_eval( $what );
     return 1;
   },

   perlhandler=>sub {
     my ($action, $what)=@_;
     add_note(response=>$what);
     $r->handler('modperl')
       unless( $r->handler=~/^(?:modperl|perl-script)$/ );

     # some perl handler use $r->location to get some "base path", e.g.
     # Catalyst. The only way to set this location is this.
     #add_note(config=>'PerlResponseHandler '.$what."\t".$MATCHED_URI);
     add_note(config=>'PerlResponseHandler '.__PACKAGE__."::response\t".$MATCHED_URI);
     add_note(shortcut_maptostorage=>" ".$MATCHED_PATH_INFO);

     # Translation done: return OK instead of DECLINED
     $RC=Apache2::Const::OK;
     return 1;
   },

   perlscript=>sub {
     my ($action, $what)=@_;
     $r->filename( scalar handle_eval( $what ) ) unless( $what=~/^\s*$/ );
     $r->handler('perl-script');
     $r->set_handlers( PerlResponseHandler=>'ModPerl::Registry' );
     add_note(fixupconfig=>'Options ExecCGI');
     add_note(fixupconfig=>'PerlOptions +ParseHeaders');
     return 1;
   },

   cgiscript=>sub {
     my ($action, $what)=@_;
     $r->filename( scalar handle_eval( $what ) ) unless( $what=~/^\s*$/ );
     $r->handler('cgi-script');
     add_note(fixupconfig=>'Options +ExecCGI');
     return 1;
   },

   proxy=>sub {
     my ($action, $what)=@_;
     my $real_url = $r->unparsed_uri;
     my $proxyreq = 1;
     if( length $what ) {
       $real_url=handle_eval( $what );
       $proxyreq=2;		# reverse proxy
     }
     add_note(fixupproxy=>"$proxyreq\t$real_url");
     return 1;
   },

   file=>sub {
     my ($action, $what)=@_;
     $r->filename( scalar handle_eval( $what ) );
     return 1;
   },

   uri=>sub {
     my ($action, $what)=@_;
     $r->uri( scalar handle_eval( $what ) );
     return 1;
   },

   config=>sub {
     my ($action, $what)=@_;
     foreach my $c (handle_eval( $what )) {
       add_note(config=>(ref $c
			 ? "$c->[0]\t$c->[1]"
			 : "$c\t$ctx->{' uri'}"));
     }
     return 1;
   },

   fixupconfig=>sub {
     my ($action, $what)=@_;
     foreach my $c (handle_eval( $what )) {
       add_note(fixupconfig=>(ref $c
			      ? "$c->[0]\t$c->[1]"
			      : "$c\t$ctx->{' uri'}"));
     }
     return 1;
   },

   key=>sub {
     my ($action, $what)=@_;
     $ctx->{' key'}=handle_eval( $what );
     return 1;
   },

   state=>sub {
     my ($action, $what)=@_;
     $what=lc handle_eval( $what );
     if( exists $states{$what} ) {
       $ctx->{' state'}=$states{$what};
     } else {
       $r->warn(__PACKAGE__.": invalid state $what");
     }
     return 1;
   },

   error=>sub {
     my ($action, $what)=@_;
     my ($code, $msg)=handle_eval( $what );
     die Apache2::Translation::Error->new( code=>$code||500,
					   msg=>$msg||'unspecified error' );
   },

   redirect=>sub {
     my ($action, $what)=@_;
     my ($loc, $code)=handle_eval( $what );
     die Apache2::Translation::Error->new( msg=>"Action REDIRECT: location not set" )
       unless( length $loc );
     die Apache2::Translation::Error->new( loc=>$loc, code=>$code||302 );
   },

   call=>sub {
     my ($action, $what)=@_;
     local @ARGV;
     ($what, @ARGV)=handle_eval( $what );
     process( $cf->{provider}->fetch( $ctx->{' key'}, $what ) );
     return 1;
   },

   restart=>sub {
     my ($action, $what)=@_;
     if( length $what ) {
       $action_dispatcher{$action}->('uri', $what);
     }
     $ctx->{' state'}=START;
     return 1;
   },

   done=>sub {
     my ($action, $what)=@_;
     $ctx->{' state'}=$next_state{$ctx->{' state'}};
     return 0;
   },

   last=>sub {
     my ($action, $what)=@_;
     return 0;
   },
  );

sub handle_action {
  my ($a)=@_;
  if( $a=~/\A(?:(\w+)(?::\s*(.+))?)|(.+)\Z/s ) {
    my ($action, $what)=(defined $1 ? lc($1) : 'do',
			 defined $1 ? $2 : $3);

    warn "Action: $action: $what\n" if($DEBUG);

    if( exists $action_dispatcher{$action} ) {
      return $action_dispatcher{$action}->($action, $what);
    }
  }

  $r->warn(__PACKAGE__.": UNKNOWN ACTION '$a' skipped");
  return 1;
}

sub process {
  my $rec=shift;

  my $block;
  my $cond=1;
  my $all_skipped=1;

  if( $rec ) {
    warn "\nState $state_names[$ctx->{' state'}]: uri = $ctx->{' uri'}\n"
      if( $DEBUG==1 );
    $block=$rec->[0];
    #warn "\ncond=$cond\nblock=$block: $rec->[1]: $rec->[2]\n";
    if( $rec->[2]=~/^COND:\s*(.+)/si ) {
      warn "Action: cond: $1\n" if($DEBUG);
      $cond &&= handle_eval( $1 );
    } elsif( $cond ) {
      handle_action( $rec->[2] ) or return 0;
      $all_skipped=0;
    }
  }

  while( $rec=shift ) {
    #warn "\ncond=$cond\nblock=$block: $rec->[1]: $rec->[2]\n";
    unless( $block==$rec->[0] ) {
      $block=$rec->[0];
      $cond=1;
    }
    if( $rec->[2]=~/^COND:\s*(.+)/si ) {
      warn "Action: cond: $1\n" if($DEBUG);
      $cond &&= handle_eval( $1 );
    } elsif( $cond ) {
      handle_action( $rec->[2] ) or return 0;
      $all_skipped=0;
    }
  }

  if( $all_skipped ) {
    $ctx->{' state'}=$default_shift{$ctx->{' state'}};
  }

  return 1;
}

sub add_config {
  my $stmts=shift;

  my @l;
  foreach my $el (@{$stmts}) {
    if( ref($el) ) {
      if( @{$el}<2 ) {
	$el=$el->[0];
      } elsif( !length $el->[1] ) {
	$el->[1]='/';
      }
    }
    if( ref($el) ) {
      if( ref($l[0]) and $l[0]->[1] eq $el->[1] ) {
	push @l, $el;
      } else {
	if( @l ) {
	  if( ref($l[0]) ) {
	    if( $DEBUG>1 ) {
	      local $"="\n  ";
	      warn "Applying Config: path=$l[0]->[1]\n  @{[map {$_->[0]} @l]}\n";
	    }
	    $r->add_config( [map {$_->[0]} @l], 0xff, $l[0]->[1] );
	  } else {
	    if( $DEBUG>1 ) {
	      local $"="\n  ";
	      warn "Applying Config: path=undef\n  @l\n";
	    }
	    $r->add_config( \@l, 0xff );
	  }
	}
	@l=($el);
      }
    } else {			# $el is a simple line
      if( ref($l[0]) ) {	# but $l[0] is not
	if( @l ) {
	  if( $DEBUG>1 ) {
	    local $"="\n  ";
	    warn "Applying Config: path=$l[0]->[1]\n  @{[map {$_->[0]} @l]}\n";
	  }
	  $r->add_config( [map {$_->[0]} @l], 0xff, $l[0]->[1] );
	}
	@l=($el);
      } else {			# and so is $l[0]
	push @l, $el;
      }
    }
  }
  if( @l ) {
    if( ref($l[0]) ) {
      if( $DEBUG>1 ) {
	local $"="\n  ";
	warn "Applying Config: path=$l[0]->[1]\n  @{[map {$_->[0]} @l]}\n";
      }
      $r->add_config( [map {$_->[0]} @l], 0xff, $l[0]->[1] );
    } else {
      if( $DEBUG>1 ) {
	local $"="\n  ";
	warn "Applying Config: path=undef\n  @l\n";
      }
      $r->add_config( \@l, 0xff );
    }
  }
}

sub maptostorage {
  my $scope=Perl::AtEndOfScope->new( \&undef_cf_r_ctx );
  $r=$_[0];

  warn "\nMapToStorage\n" if( $DEBUG>1 );

  my $rc=Apache2::Const::DECLINED;

  my @config=$r->notes->get(__PACKAGE__."::config");
  if( @config ) {
    add_config([map {my @l=split /\t/, $_, 2; @l==2 ? [@l] : $_} @config]);
  }

  my $shortcut=$r->notes->get(__PACKAGE__."::shortcut_maptostorage");
  if( $shortcut ) {
    warn "PERLHANDLER: short cutting MapToStorage\n" if($DEBUG>1);
    unless(defined $r->path_info) {
      my $pi=substr($shortcut, 1);
      warn "PERLHANDLER: setting path_info to '$pi'\n" if($DEBUG>1);
      $r->path_info($pi);
    }
    $rc=Apache2::Const::OK;
  }

  return $rc;
}

sub fixup {
  my $scope=Perl::AtEndOfScope->new( \&undef_cf_r_ctx );
  $r=$_[0];

  warn "\nFixup\n" if( $DEBUG>1 );

  my @config=$r->notes->get(__PACKAGE__."::fixupconfig");
  if( @config ) {
    add_config([map {my @l=split /\t/, $_, 2; @l==2 ? [@l] : $_} @config]);
  }
  my $proxy=$r->notes->get(__PACKAGE__."::fixupproxy");
  if( length $proxy ) {
    my @l=split /\t/, $proxy;
    warn( ($l[0]==2?"REVERSE ":'')."PROXY to $l[1]\n" ) if($DEBUG>1);
    $r->proxyreq($l[0]);
    $r->filename("proxy:$l[1]");
    $r->handler('proxy_server');
  }

  return Apache2::Const::DECLINED;
}

sub response {
  my $scope=Perl::AtEndOfScope->new( \&undef_cf_r_ctx );
  $r=$_[0];

  my $handler;
  my $what=$r->notes->get(__PACKAGE__."::response");
  $what=handle_eval( $what );

  no strict 'refs';
  $handler=(defined(&{$what})?\&{$what}:
	    defined(&{$what.'::handler'})?\&{$what.'::handler'}:
	    $what->can('handler')?sub {$what->handler(@_)}:
	    $what);

  if( ref $handler eq 'CODE' ) {
    unshift @_, $what if( grep $_ eq 'method', attributes::get($handler) );
    goto $handler;
  }

  unless( ref $handler ) {
    # handler routine not defined yet. try to load a module
    eval "require $handler";
    if( $@ ) {
      if( $handler=~s/::\w+$// ) {
	# retry without the trailing ::handler
	eval "require $handler";
      }
    }
    $r->warn( __PACKAGE__.": Handler module $handler loaded -- consider to load it at server startup" )
      unless( $@ );
    $handler=(defined(&{$what})?\&{$what}:
	      defined(&{$what.'::handler'})?\&{$what.'::handler'}:
	      $what->can('handler')?sub {$what->handler(@_)}:
	      $what);

    if( ref $handler eq 'CODE' ) {
      unshift @_, $what if( grep $_ eq 'method', attributes::get($handler) );
      goto $handler;
    }

    $r->warn( __PACKAGE__.": Cannot find handler $what".($@?": $@":'') );
  }
  return Apache2::Const::SERVER_ERROR;
}

my @state_machine=
  (
   # START
   sub {
     @{$ctx}{' key', ' uri', ' pathinfo', ' state'}=($cf->{key}, $r->uri, '', PREPROC);
     $ctx->{' uri'}=~s!/+!/!g;
     die Apache2::Translation::Error->new( code=>Apache2::Const::HTTP_BAD_REQUEST,
					   msg=>"BAD REQUEST: $ctx->{' uri'}" )
       unless( $ctx->{' uri'}=~m!^/! or $ctx->{' uri'} eq '*' );
   },

   # PREPROC
   sub {
     my $k=$ctx->{' key'};
     process( $cf->{provider}->fetch( $k, PRE_URI ) );
     $ctx->{' state'}=PROC
       if( $k eq $ctx->{' key'} and $ctx->{' state'}==PREPROC );
     $ctx->{' state'}=LAST_ROUND
       if( $ctx->{' state'}==PROC and $ctx->{' uri'} eq '/' );
   },

   # PROC
   sub {
     process( $cf->{provider}->fetch( $ctx->{' key'}, $ctx->{' uri'} ) );
     $ctx->{' uri'}=~s!(/[^/]*)$!! and
       $ctx->{' pathinfo'}=$1.$ctx->{' pathinfo'};
     unless( length $ctx->{' uri'} ) {
       $ctx->{' uri'}='/';
       $ctx->{' state'}=LAST_ROUND if( $ctx->{' state'}==PROC );
     }
   },

   # LAST_ROUND
   sub {
     $ctx->{' state'}=PROC;	# fake PROC state
     process( $cf->{provider}->fetch( $ctx->{' key'}, $ctx->{' uri'} ) );
     $ctx->{' state'}=DONE if( $ctx->{' state'}==PROC );
   },
  );

sub handler {
  my $scope=Perl::AtEndOfScope->new( \&undef_cf_r_ctx );
  $r=shift;

  $cf=Apache2::Module::get_config(__PACKAGE__, $r->server);
  my $prov=$cf->{provider};

  $ctx={' state'=>START};
  eval {
    $prov->start;

    while( $ctx->{' state'}!=DONE ) {
      warn "\nState $state_names[$ctx->{' state'}]: uri = $ctx->{' uri'}\n"
	if( $DEBUG>1 );
      $state_machine[$ctx->{' state'}]->();
    }

    $r->push_handlers( PerlFixupHandler=>__PACKAGE__.'::fixup' );
    $r->push_handlers( PerlMapToStorageHandler=>__PACKAGE__.'::maptostorage' );

    warn "proceed with URI '".$r->uri."' and FILENAME '".$r->filename."'\n"
      if( $DEBUG );

    $prov->stop;
  };

  if( $@ ) {
    if( ref($@) eq 'Apache2::Translation::Error' ) {
      $@->{code}=Apache2::Const::SERVER_ERROR unless( exists $@->{code} );

      if( exists $@->{loc} and 300<=$@->{code} and $@->{code}<=399 ) {
	my $loc=$@->{loc};
	unless( $loc=~/^\w+:/ ) {
	  unless( $loc=~m!^/! ) {
	    my $uri=$r->uri;
	    $uri=~s![^/]*$!!;
	    $loc=$uri.$loc;
	  }

	  my $host=$r->headers_in->{Host} || $r->hostname;
	  $host=~s/:\d+$//;

	  if( $r->connection->is_https ) {
	    if( $r->connection->local_addr->port!=443 ) {
	      $loc=':'.$r->connection->local_addr->port.$loc;
	    }
	    $loc='https://'.$host.$loc;
	  } else {
	    if( $r->connection->local_addr->port!=80 ) {
	      $loc=':'.$r->connection->local_addr->port.$loc;
	    }
	    $loc='http://'.$host.$loc;
	  }
	}
	$r->err_headers_out->{Location}=$loc;
	# change status of $r->prev if $r is the result of an ErrorDocument
	my $er=$r->prev;
	if( $er ) {
	  while( $er->prev ) {$er=$er->prev};
	  $er->status($@->{code});
	}
      }

      if( exists $@->{msg} ) {
	$@->{msg}=~s/\s*$//;
	$r->log_reason(__PACKAGE__.": $@->{msg}");
      }

      return $@->{code};
    } else {
      (my $e=$@)=~s/\s*$//;
      $r->log_reason(__PACKAGE__.": TranslationProvider error: $e");
      return Apache2::Const::SERVER_ERROR;
    }
  }

  return $RC if( defined $RC );
  return length $r->filename ? Apache2::Const::OK : Apache2::Const::DECLINED;
}

sub Config {
  my $r=shift;

  $cf=Apache2::Module::get_config(__PACKAGE__, $r->server);

  $r->content_type('text/plain');

  my $cache=$cf->{eval_cache};
  if( tied %{$cache} ) {
    $cache=tied( %{$cache} )->max_size;
  } else {
    $cache='unlimited';
  }
  $r->print( YAML::Dump( {
			  TranslationKey=>$cf->{key},
			  TranslationProvider=>$cf->{provider_param},
			  TranslationEvalCache=>$cache,
			 } ) );

  return Apache2::Const::OK;
}

1;
__END__
