#!perl

use strict;
use warnings FATAL => 'all';

use lib "../lib"; # test against the source lib for easier dev
use lib map {("../blib/$_", "../../blib/$_")} qw(lib arch);

my ($db,$user,$pw)=@ENV{qw/DB USER PW/};

if( defined $db and length $db ) {
  warn "# Using Database $db\n";
} else {
  warn "# Using Database dbi:SQLite:t/test.sqlite\n";
}

package MyTest;

use Apache::Test ();
use Apache::TestRunPerl ();
use base qw(Apache::TestRunPerl);

# subclass new_test_config to add some config vars which will be
# replaced in generated httpd.conf
sub new_test_config {
  my $self=shift;

  $self->{conf_opts}->{maxclients}=2;
  $self=$self->SUPER::new_test_config;

  my $serverroot=Apache::Test::vars->{serverroot};
  my $confdir=Apache::Test::vars->{t_conf};
  unless( defined $db and length $db ) {
    ($db,$user,$pw)=("dbi:SQLite:dbname=$serverroot/test.sqlite", '', '');
  }

  open my $f, ">$confdir/db.inc" or
    die "ERROR: Cannot write to $confdir/db.inc: $!\n";
  do {
    no warnings 'uninitialized';
    if( $ENV{INTERP_SCOPE} ) {
      warn "# Using PerlInterpScope $ENV{INTERP_SCOPE}\n";
      print $f <<"EOF";
<IfModule worker.c>
    PerlInterpScope $ENV{INTERP_SCOPE}
</IfModule>
EOF
    }
    if( $ENV{OLD_INTERFACE} ) {
      print $f <<"EOF";
TranslationProvider DB \\
		    "Database=$db" \\
		    "User=$user" "Password=$pw" \\
		    table=trans \\
		    key=xkey uri=xuri block=xblock order=xorder action=xaction id=id \\
		    cachetbl=cache cachecol=v singleton=1
EOF
    } else {
    print $f <<"EOF";
<TranslationProvider DB>
    Database  "$db"
    User      "$user"
    Password  "$pw"
    Table     trans
    Id        id
    Key       xkey
    Uri       xuri
    Block     xblock
    Order     xorder
    Action    xaction
    Cachetbl  cache
    Cachecol  v
    Singleton 1
</TranslationProvider>
EOF
    }
  };
  close $f or
    die "ERROR: Cannot write to $confdir/db.inc: $!\n";

  return $self;
}

MyTest->new->run(@ARGV);
